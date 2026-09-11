@tool
extends AiTool

## 纯视口截图：截取编辑器 3D 视口画面本身，不叠加任何节点标注。
##
## 与 capture_node_annotated_screenshot 的分工：
##   - 本工具：看图 —— 材质 / shader / 顶点动画 / 光照的实际渲染效果，画面干净
##   - 那个工具：看节点 —— mask / box 标注会覆盖画面，且顶点动画的 mask 是静止形状
##
## 使用要点：
##   - 编辑器需处于 3D 主屏（工具会自动切换）
##   - 顶点动画（GPU compute 驱动）依赖编辑器持续渲染；若画面明显没更新，
##     请在「编辑器设置 → 界面 → 编辑器 → 更新方式」开启 Update Continuously

const DEFAULT_MAX_WIDTH: int = 1000
const DEFAULT_WAIT_FRAMES: int = 3
const MAX_WAIT_FRAMES: int = 30


func _init() -> void:
	tool_name = "capture_viewport_screenshot"
	tool_description = "Captures a clean screenshot of the editor's 3D viewport (no annotation overlay), optionally cropped and downscaled. Use it to inspect actual rendering: materials, shaders, vertex animation, lighting."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"max_width": {
				"type": "integer",
				"description": "Downscale so image width does not exceed this value (aspect kept). Default 1000. Smaller = cheaper, larger = more detail.",
				"default": DEFAULT_MAX_WIDTH
			},
			"crop": {
				"type": "array",
				"items": {"type": "number"},
				"description": "Optional normalized crop [x, y, w, h] in 0..1 (origin top-left), applied BEFORE downscaling. Use it to zoom into a region of interest."
			},
			"wait_frames": {
				"type": "integer",
				"description": "Rendered frames to wait before capturing. Default 3. Raise it when the scene updates asynchronously (e.g. GPU compute vertex animation).",
				"default": DEFAULT_WAIT_FRAMES
			},
			"viewport_index": {
				"type": "integer",
				"description": "3D viewport index (0-3). Default 0 (main perspective viewport).",
				"default": 0
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")

	var viewport_index: int = int(p_args.get("viewport_index", 0))
	var max_width: int = int(p_args.get("max_width", DEFAULT_MAX_WIDTH))
	var wait_frames: int = clampi(int(p_args.get("wait_frames", DEFAULT_WAIT_FRAMES)), 1, MAX_WAIT_FRAMES)
	var crop: Array = p_args.get("crop", [])

	EditorInterface.set_main_screen_editor("3D")
	var viewport: Viewport = EditorInterface.get_editor_viewport_3d(viewport_index)
	if viewport == null:
		return ToolResult.fail("Error: no 3D viewport found at index %d." % viewport_index)

	# 等若干帧，确保拿到最新渲染结果（顶点动画 / GPU compute 输出）
	for _i in wait_frames:
		await RenderingServer.frame_post_draw

	var image: Image = viewport.get_texture().get_image()
	if image == null:
		return ToolResult.fail("Error: failed to capture viewport image.")

	var info: PackedStringArray = PackedStringArray()
	var scene_root: Node = EditorInterface.get_edited_scene_root()
	info.append("scene: %s" % ("(none)" if scene_root == null else str(scene_root.name)))
	info.append("viewport %d | native %dx%d" % [viewport_index, image.get_width(), image.get_height()])

	if crop.size() >= 4:
		var w: int = image.get_width()
		var h: int = image.get_height()
		var cx: int = clampi(int(float(crop[0]) * float(w)), 0, w - 1)
		var cy: int = clampi(int(float(crop[1]) * float(h)), 0, h - 1)
		var cw: int = clampi(int(float(crop[2]) * float(w)), 1, w - cx)
		var ch: int = clampi(int(float(crop[3]) * float(h)), 1, h - cy)
		image = image.get_region(Rect2i(cx, cy, cw, ch))
		info.append("crop [%d, %d, %d, %d]" % [cx, cy, cw, ch])

	if image.get_width() > max_width:
		var nh: int = maxi(int(round(float(image.get_height()) * float(max_width) / float(image.get_width()))), 1)
		image.resize(max_width, nh, Image.INTERPOLATE_LANCZOS)
		info.append("downscaled to %dx%d" % [max_width, nh])

	info.append(_describe_camera(viewport))
	return ToolResult.ok_with_image("\n".join(info), image.save_png_to_buffer(), "image/png")


# 描述当前相机状态，便于理解截图视角。
func _describe_camera(p_viewport: Viewport) -> String:
	var cam: Camera3D = p_viewport.get_camera_3d()
	if cam == null:
		return "camera: (none)"
	var pos: Vector3 = cam.global_position
	var fwd: Vector3 = -cam.global_transform.basis.z
	return "camera: pos (%.2f, %.2f, %.2f) | fwd (%.2f, %.2f, %.2f) | fov %.0f | %s" % [
		pos.x, pos.y, pos.z, fwd.x, fwd.y, fwd.z, cam.fov,
		"ortho" if cam.projection == Camera3D.PROJECTION_ORTHOGONAL else "perspective"]
