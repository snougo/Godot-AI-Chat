@tool
extends BaseSceneTool

## 捕获场景视窗截图工具
## 
## 捕获当前编辑器3D或2D视窗的画面，返回截图数据供AI分析。
## 根据场景根节点类型自动选择视窗（Node2D/Control → 2D，Node3D → 3D），
## 也可通过 viewport_type 参数手动指定。

# --- Built-in Functions ---

func _init() -> void:
	tool_name = "capture_edited_scene_screenshot"
	tool_description = "Captures a screenshot of the current edited scene viewport in the Godot Editor."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"viewport_type": {
				"type": "string",
				"description": "Force screenshot from '2D' or '3D' viewport.",
				"enum": ["2D", "3D"]
			}
		},
		"required": ["viewport_type"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")
	
	# 获取当前编辑的场景根节点
	var root: Node = get_active_scene_root()
	if not root:
		return ToolResult.fail("Error: no active scene in editor.")
	
	var viewport: SubViewport = null
	var viewport_type: String = ""
	
	# 优先使用手动指定的视窗类型，否则根据场景根节点类型自动判断
	if p_args.has("viewport_type") and not p_args["viewport_type"] == null:
		viewport_type = p_args["viewport_type"]
	elif root is Node2D or root is Control:
		viewport_type = "2D"
	else:
		viewport_type = "3D"
	
	# 按类型获取视窗并自动切换标签
	if viewport_type == "2D":
		viewport = EditorInterface.get_editor_viewport_2d()
		if viewport:
			EditorInterface.set_main_screen_editor("2D")
	else:
		viewport = EditorInterface.get_editor_viewport_3d()
		if viewport:
			EditorInterface.set_main_screen_editor("3D")
	
	if not viewport:
		return ToolResult.fail("Error: no %s viewport available." % viewport_type)
	
	# 等待渲染完成
	await RenderingServer.frame_post_draw
	
	# 获取视窗纹理并转换为图像
	var viewport_texture: ViewportTexture = viewport.get_texture()
	var image: Image = viewport_texture.get_image()
	
	# 获取实际尺寸
	var width: int = image.get_width()
	var height: int = image.get_height()
	
	# 将图像编码为 PNG
	var png_buffer: PackedByteArray = image.save_png_to_buffer()
	
	return ToolResult.ok_with_image("Viewport screenshot captured successfully. Type: %s, Resolution: %dx%d. The image is attached to this message." % [viewport_type, width, height],
		png_buffer,
		"image/png"
	)
