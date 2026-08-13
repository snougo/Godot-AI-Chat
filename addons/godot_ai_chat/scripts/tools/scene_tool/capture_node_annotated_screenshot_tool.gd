@tool
extends BaseSceneTool

## 场景标注截图工具（v3.1：仅服务 3D 场景）
##
## 截取当前编辑器 3D 视窗画面，并叠加可见节点的标注（ID + 名称标签）。
## 支持两种标注模式：
##   - mask（默认）：离屏渲染像素级实例 ID 图，生成与物体轮廓精确吻合的
##     半透明填充 + 轮廓描边，并提供精确可见像素统计（pixels / % of screen）。
##     遮挡关系由渲染管线深度测试天然保证，不依赖物理碰撞体。
##   - box（legacy）：AABB 投影矩形框 + 距离衰减透明度 + 9 采样点射线遮挡。
##
## 本工具仅处理 3D 场景（Node3D 层级）；2D / UI（Control）节点一律忽略。
## 点状节点（Light3D/Camera3D/Marker3D/Area3D/AudioStreamPlayer3D）不参与 mask，
## 以屏幕十字图标 + 标签标注（mask 与 box 模式均生效）。
##
## 已知局限：
##   - mask 模式仅对 MeshInstance3D 生成 mask；其余类型（CSG/MultiMesh/GridMap）
##     自动回退 box 模式。
##   - shader 顶点动画（水面/旗帜等）mask 为静止形状（代理不含顶点 shader）。
##   - 半透明/透明材质按不透明处理，mask 与原图可能略有出入。


# --- Constants ---

const DEFAULT_MAX_NODES: int = 40
const POINT_SIZE_EPS: float = 0.011
const OVERLAY_Z: int = 4096
const MAX_DISPLAY_DEPTH: int = 4  ## 重名节点显示名最大祖先层数（含自身）
const MASK_FILL_ALPHA: int = 90   ## 半透明填充 alpha (0.35 * 255)
const MASK_OUTLINE_ALPHA: int = 255
const POINT_ICON_RADIUS: float = 4.0  ## 点状节点十字图标半长


# --- Inner Class: 标注覆盖层（绘制在视窗 3D 画面之上） ---

class AnnotationOverlay extends Control:
	## 绘制项（box 模式）: {rect: Rect2, id: String, name: String, color: Color}
	## 绘制项（mask 模式）: [{texture: ImageTexture, labels: [{id, name, anchor, color, icon}]}]
	var items: Array = []
	var show_labels: bool = true
	var label_names: bool = true
	var font_size: int = 13
	const LABEL_BG := Color(0.0, 0.0, 0.0, 0.78)
	## 框面积超过视口该比例时改画四角 L 标
	const BIG_BOX_RATIO := 0.55
	const CORNER_LEN := 24.0
	## 标签与锚点间距
	const LABEL_GAP := 4.0

	func _draw() -> void:
		var font: Font = ThemeDB.fallback_font
		var placed_labels: Array[Rect2] = []
		var viewport_area: float = size.x * size.y
		# mask 模式检测（任一绘制项含 texture 键）
		var has_texture: bool = false
		for it in items:
			if it.has("texture"):
				has_texture = true
				break
		if has_texture:
			_draw_mask(font, placed_labels)
			return
		_draw_boxes(font, placed_labels, viewport_area)

	# --- mask 模式：整张 overlay 纹理 + 锚点标签 ---

	func _draw_mask(p_font: Font, p_placed: Array[Rect2]) -> void:
		var labels: Array = []
		for it in items:
			var tex: Texture2D = it.get("texture") as Texture2D
			if tex != null:
				draw_texture(tex, Vector2.ZERO)
			labels.append_array(it.get("labels", []))
		# 先画全部点状节点图标（避免被标签盖住）
		for lb in labels:
			if lb.get("icon", false):
				_draw_point_icon(lb)
		if not show_labels:
			return
		for lb in labels:
			_place_mask_label(p_font, lb, p_placed)

	# 点状节点：在锚点画十字 + 中心方块图标
	func _draw_point_icon(p_lb: Dictionary) -> void:
		var col: Color = p_lb.get("color", Color.YELLOW)
		var a: Vector2 = p_lb.get("anchor", Vector2.ZERO)
		var r: float = POINT_ICON_RADIUS
		draw_line(a + Vector2(-r, 0.0), a + Vector2(r, 0.0), col, 2.0)
		draw_line(a + Vector2(0.0, -r), a + Vector2(0.0, r), col, 2.0)
		draw_rect(Rect2(a - Vector2(1.5, 1.5), Vector2(3.0, 3.0)), col, true)

	# 以 mask 质心/图标为锚点摆放标签（8 向候选 + 推挤回退），自动避让
	func _place_mask_label(p_font: Font, p_lb: Dictionary, p_placed: Array[Rect2]) -> void:
		var text: String = String(p_lb.get("id", ""))
		if label_names and not String(p_lb.get("name", "")).is_empty():
			text += " " + String(p_lb.name)
		var col: Color = p_lb.get("color", Color.YELLOW)
		var fs: float = float(font_size)
		var w: float = p_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var bg_size := Vector2(w + 8.0, fs + 6.0)
		var anchor: Vector2 = p_lb.get("anchor", Vector2.ZERO)
		var candidates := _mask_label_candidates(anchor, bg_size)
		var chosen := _find_free_label_pos(candidates, bg_size, p_placed, anchor)
		p_placed.append(chosen)
		draw_rect(chosen, LABEL_BG, true)
		draw_string(p_font, chosen.position + Vector2(4.0, fs + 1.0), text,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)

	# 围绕锚点的 8 向候选框位置（上 → 右上 → 右 → 右下 → 下 → 左下 → 左 → 左上）
	func _mask_label_candidates(p_anchor: Vector2, p_bg: Vector2) -> Array:
		var gap: float = LABEL_GAP
		return [
			Vector2(p_anchor.x - p_bg.x * 0.5, p_anchor.y - p_bg.y - gap),
			Vector2(p_anchor.x + gap, p_anchor.y - p_bg.y - gap),
			Vector2(p_anchor.x + gap, p_anchor.y - p_bg.y * 0.5),
			Vector2(p_anchor.x + gap, p_anchor.y + gap),
			Vector2(p_anchor.x - p_bg.x * 0.5, p_anchor.y + gap),
			Vector2(p_anchor.x - p_bg.x - gap, p_anchor.y + gap),
			Vector2(p_anchor.x - p_bg.x - gap, p_anchor.y - p_bg.y * 0.5),
			Vector2(p_anchor.x - p_bg.x - gap, p_anchor.y - p_bg.y - gap),
		]

	# --- box 模式：现有矩形框 + 标签逻辑 ---

	func _draw_boxes(p_font: Font, p_placed: Array[Rect2], p_viewport_area: float) -> void:
		for it in items:
			var rect: Rect2 = it.rect
			var col: Color = it.color
			# --- 框（超大框降级为角标） ---
			if rect.get_area() > p_viewport_area * BIG_BOX_RATIO:
				_draw_corner_marks(rect, col)
			else:
				draw_rect(rect, col, false, 2.0)
			# --- 标签（自动避让，8 向 + 推挤） ---
			if not show_labels:
				continue
			var text: String = String(it.id)
			if label_names and not String(it.name).is_empty():
				text += " " + String(it.name)
			var fs: float = float(font_size)
			var w: float = p_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
			var bg_size := Vector2(w + 8.0, fs + 6.0)
			var candidates := [
				Vector2(rect.position.x, rect.position.y - bg_size.y - 4.0),
				Vector2(rect.position.x, rect.position.y + 4.0),
				Vector2(rect.position.x, rect.end.y - bg_size.y - 4.0),
				Vector2(rect.end.x - bg_size.x, rect.position.y + 4.0),
			]
			var chosen := _find_free_label_pos(candidates, bg_size, p_placed, rect.get_center())
			p_placed.append(chosen)
			draw_rect(chosen, LABEL_BG, true)
			draw_string(p_font, chosen.position + Vector2(4.0, fs + 1.0), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, col)

	# 超大框只画四角 L 形标记
	func _draw_corner_marks(p_rect: Rect2, p_col: Color) -> void:
		var l: float = CORNER_LEN
		var w: float = 2.5
		var p0: Vector2 = p_rect.position
		var p1 := Vector2(p_rect.end.x, p_rect.position.y)
		var p2: Vector2 = p_rect.end
		var p3 := Vector2(p_rect.position.x, p_rect.end.y)
		draw_line(p0, p0 + Vector2(l, 0), p_col, w)
		draw_line(p0, p0 + Vector2(0, l), p_col, w)
		draw_line(p1, p1 + Vector2(-l, 0), p_col, w)
		draw_line(p1, p1 + Vector2(0, l), p_col, w)
		draw_line(p2, p2 + Vector2(-l, 0), p_col, w)
		draw_line(p2, p2 + Vector2(0, -l), p_col, w)
		draw_line(p3, p3 + Vector2(l, 0), p_col, w)
		draw_line(p3, p3 + Vector2(0, -l), p_col, w)

	# --- 标签避让公共逻辑 ---

	# 在候选位中找不越界且不与已放置标签重叠的位置；
	# 全部失败则以 p_anchor 为起点沿"锚点 → 屏幕中心"方向逐步推挤；仍失败则夹紧返回候选 0
	func _find_free_label_pos(p_candidates: Array, p_bg_size: Vector2,
			p_placed: Array[Rect2], p_anchor: Vector2) -> Rect2:
		for c in p_candidates:
			var r := Rect2(c, p_bg_size)
			if r.position.x < 0.0 or r.position.y < 0.0 or r.end.x > size.x or r.end.y > size.y:
				continue
			if not _overlaps_any(r, p_placed):
				return r
		# 推挤回退
		var dir: Vector2 = (size * 0.5 - p_anchor)
		if dir.length() < 0.001:
			dir = Vector2.DOWN
		else:
			dir = dir.normalized()
		for k in range(1, 32):
			var r := Rect2(p_anchor + dir * (6.0 * k) - p_bg_size * 0.5, p_bg_size)
			r.position = r.position.max(Vector2.ZERO)
			r.position = r.position.min(size - r.size)
			if not _overlaps_any(r, p_placed):
				return r
		# 最终兜底：候选 0 夹紧
		var fallback := Rect2(p_candidates[0], p_bg_size)
		fallback.position = fallback.position.max(Vector2.ZERO)
		fallback.position = fallback.position.min(size - fallback.size)
		return fallback

	func _overlaps_any(p_rect: Rect2, p_placed: Array[Rect2]) -> bool:
		for p in p_placed:
			if p_rect.intersects(p):
				return true
		return false


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "capture_node_annotated_screenshot"
	tool_description = "Captures the edited 3D scene viewport as an image with node annotations (pixel-exact instance masks or bounding boxes) overlaid."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"max_nodes": {
				"type": "integer",
				"description": "Maximum nodes to annotate (nearest ones kept). Default 40. Range [1, 200]."
			},
			"exclude_nodes": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Node names or path suffixes to exclude with their subtrees."
			},
			"annotation_mode": {
				"type": "string",
				"enum": ["mask", "box"],
				"description": "'mask' (default): pixel-exact instance masks with precise pixel counts (auto-falls back to box). 'box': legacy AABB boxes with raycast occlusion."
			},
			"verbose": {
				"type": "boolean",
				"description": "Full legend output (default true). Set false for a compact legend (header + legend lines only, no mode notes / not-annotated list / notes section)."
			}
		},
		"required": ["max_nodes"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")
	
	var root: Node = get_active_scene_root()
	if not root:
		return ToolResult.fail("Error: no active scene in editor.")
	
	var viewport: Viewport = _get_viewport()
	var max_nodes: int = clampi(int(p_args.get("max_nodes", DEFAULT_MAX_NODES)), 1, 200)
	var exclude_nodes: Array = p_args.get("exclude_nodes", [])
	var annotation_mode: String = "box"
	if str(p_args.get("annotation_mode", "mask")).to_lower() == "mask":
		annotation_mode = "mask"
	var verbose: bool = bool(p_args.get("verbose", true))
	
	# 1. 收集 3D 节点
	var entries: Array[Dictionary] = _collect_3d_entries(root, exclude_nodes)
	if entries.is_empty():
		return ToolResult.fail("Error: no annotatable 3D nodes found.")
	
	# 2. 投影 + 排序 + 过滤（返回被剔除的节点列表）
	var screen_size: Vector2 = viewport.get_visible_rect().size
	var camera: Camera3D = viewport.get_camera_3d()
	if not camera:
		return ToolResult.fail("Error: 3D viewport has no active camera.")
	# mask 模式跳过物理射线遮挡（由 ID 缓冲深度测试精确处理）
	var out_of_view: Array[Dictionary] = _annotate_3d(entries, camera, screen_size, max_nodes, annotation_mode == "box")
	if entries.is_empty():
		return ToolResult.fail("Error: all nodes are outside the viewport or fully occluded.")
	
	# 3. 稳定 ID + 重名消歧 + 色板
	_assign_ids(entries)
	_assign_display_names(entries)
	_apply_colors(entries)
	
	# 3.5 mask 模式：离屏 ID 渲染 + 像素统计 + overlay 合成
	var mask_overlay_img: Image = null
	var mask_used: bool = false
	var mask_note: String = ""
	if annotation_mode == "mask" and camera != null:
		var mr: Dictionary = await _run_mask_pass(entries, camera, screen_size)
		if mr.is_empty():
			mask_note = "Mask pass failed; fell back to box mode."
		else:
			mask_overlay_img = mr.get("overlay") as Image
			mask_used = mask_overlay_img != null
			if not mask_used:
				mask_note = "Mask overlay generation failed; fell back to box mode."
	
	# 4. 创建标注覆盖层
	var overlay := AnnotationOverlay.new()
	overlay.name = "AIAnnotationOverlay"
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.z_index = OVERLAY_Z
	overlay.show_labels = true
	overlay.label_names = true
	overlay.items = _build_draw_items(entries, mask_overlay_img, mask_used)
	viewport.add_child(overlay)
	overlay.queue_redraw()
	
	# 5. 等待渲染完成（两帧确保覆盖层绘制）
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	
	# 6. 截图
	var image: Image = viewport.get_texture().get_image()
	if image == null:
		if overlay.get_parent() != null:
			overlay.get_parent().remove_child(overlay)
			overlay.free()
		return ToolResult.fail("Error: failed to capture viewport image.")
	var png: PackedByteArray = image.save_png_to_buffer()
	if overlay.get_parent() != null:
		overlay.get_parent().remove_child(overlay)
		overlay.free()
	
	# 7. 构建图例文本并返回
	var legend: String = _build_legend(entries, out_of_view, screen_size,
		str(root.get_path()), verbose, mask_used, mask_note)
	return ToolResult.ok_with_image(legend, png, "image/png")


# --- Private: 视口获取 ---

func _get_viewport() -> Viewport:
	EditorInterface.set_main_screen_editor("3D")
	return EditorInterface.get_editor_viewport_3d() as Viewport


# --- Private: 3D 节点收集 ---

func _collect_3d_entries(p_root: Node, p_excludes: Array) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	_collect_recursive_3d(p_root, result, str(p_root.get_path()), p_excludes)
	return result


func _collect_recursive_3d(p_node: Node, p_out: Array[Dictionary], p_root_path: String, p_excludes: Array) -> void:
	if _is_excluded(p_node, p_root_path, p_excludes):
		return
	if p_node is Node3D and p_node.is_visible_in_tree():
		var entry: Dictionary = _make_3d_entry(p_node)
		if not entry.is_empty():
			p_out.append(entry)
	for child in p_node.get_children():
		_collect_recursive_3d(child, p_out, p_root_path, p_excludes)


func _make_3d_entry(p_node: Node3D) -> Dictionary:
	var world_corners: Array[Vector3] = []
	var is_point: bool = false
	if p_node is GeometryInstance3D or p_node is GridMap:
		var local: AABB = p_node.get_aabb()
		if local.size.x > 0.0 or local.size.y > 0.0 or local.size.z > 0.0:
			world_corners = _transform_aabb_corners(local, p_node.global_transform)
		else:
			world_corners = _transform_aabb_corners(
				AABB(p_node.global_position, Vector3(0.01, 0.01, 0.01)), Transform3D.IDENTITY)
	elif p_node is Camera3D or p_node is Light3D or p_node is Marker3D or p_node is Area3D or p_node is AudioStreamPlayer3D:
		is_point = true
		world_corners = _transform_aabb_corners(
			AABB(p_node.global_position, Vector3(0.01, 0.01, 0.01)), Transform3D.IDENTITY)
	if world_corners.is_empty():
		return {}
	# 由真实角点重建世界 AABB（用于距离排序与图例）
	var world_aabb := AABB(world_corners[0], Vector3.ZERO)
	for i in range(1, world_corners.size()):
		world_aabb = world_aabb.expand(world_corners[i])
	return {
		"node": p_node,
		"corners": world_corners,
		"aabb": world_aabb,
		"name": p_node.name,
		"class": p_node.get_class(),
		"path": str(p_node.get_path()),
		"point": is_point,
	}


# --- Private: 排除规则 ---

func _is_excluded(p_node: Node, p_root_path: String, p_excludes: Array) -> bool:
	if p_excludes.is_empty():
		return false
	var full: String = str(p_node.get_path())
	var rel: String = full
	if full.begins_with(p_root_path):
		rel = full.substr(p_root_path.length()).trim_prefix("/")
	for ex in p_excludes:
		var e: String = String(ex).strip_edges().trim_prefix("/")
		if e.is_empty():
			continue
		if p_node.name == e:
			return true
		if rel == e:
			return true
		if rel.begins_with(e + "/"):
			return true
		if rel.ends_with("/" + e):
			return true
	return false


# --- Private: 3D 投影标注 ---

func _annotate_3d(p_entries: Array[Dictionary], p_camera: Camera3D,
		p_screen_size: Vector2, p_max: int, p_use_occlusion: bool = true) -> Array[Dictionary]:
	var cam_pos: Vector3 = p_camera.global_position
	# 1. 距离排序（近 → 远）
	p_entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return ((a.aabb as AABB).get_center()).distance_squared_to(cam_pos) \
			< ((b.aabb as AABB).get_center()).distance_squared_to(cam_pos))
	# 2. 截断（被截掉的也计入剔除列表）
	var culled: Array[Dictionary] = []
	while p_entries.size() > p_max:
		culled.append(p_entries.pop_back())
	# 3. 投影真实角点 + 过滤不可见
	var visible: Array[Dictionary] = []
	for e in p_entries:
		var corners: Array[Vector3] = e.get("corners", []) as Array[Vector3]
		if corners == null or corners.is_empty():
			culled.append(e)
			continue
		var r: Rect2 = _project_world_corners(corners, p_camera, p_screen_size)
		if r.size.x > 0.0 and r.size.y > 0.0:
			e["rect"] = r
			e["dist"] = (e.aabb as AABB).get_center().distance_to(cam_pos)
			visible.append(e)
		else:
			culled.append(e)
	p_entries.clear()
	p_entries.append_array(visible)
	# 4. 距离衰减透明度（存入 alpha，颜色后统一应用）
	var max_dist := 1.0
	for e in p_entries:
		max_dist = maxf(max_dist, e.dist)
	for e in p_entries:
		e["alpha"] = clampf(1.2 - 0.8 * (e.dist / max_dist), 0.35, 1.0)
	# 5. 射线遮挡检测（完全遮挡的移入 culled；mask 模式跳过，由 ID 缓冲精确处理）
	if p_use_occlusion:
		_apply_occlusion(p_entries, p_camera, culled)
	return culled


func _project_world_corners(p_corners: Array[Vector3], p_camera: Camera3D, p_screen_size: Vector2) -> Rect2:
	var min_pt := Vector2(INF, INF)
	var max_pt := Vector2(-INF, -INF)
	var any_front: bool = false
	for corner in p_corners:
		if p_camera.is_position_behind(corner):
			continue
		any_front = true
		var sp: Vector2 = p_camera.unproject_position(corner)
		min_pt = min_pt.min(sp)
		max_pt = max_pt.max(sp)
	if not any_front:
		return Rect2()
	min_pt = min_pt.max(Vector2.ZERO)
	max_pt = max_pt.min(p_screen_size)
	if max_pt.x < min_pt.x or max_pt.y < min_pt.y:
		return Rect2()
	return Rect2(min_pt, max_pt - min_pt)


func _transform_aabb_corners(p_local: AABB, p_xform: Transform3D) -> Array[Vector3]:
	var result: Array[Vector3] = []
	for c in _aabb_corners(p_local):
		result.append(p_xform * c)
	return result


# 射线遮挡检测：向节点 9 个采样点（中心 + 8 角点）发射物理射线，
# 统计可见比例。完全遮挡（0/9）移入 culled；部分遮挡按比例降低 alpha。
# 场景无碰撞体时所有采样点均未命中 → 全部可见 → 自动降级为无操作。
# （仅 box 模式使用；mask 模式由 ID 缓冲深度测试精确处理遮挡）
func _apply_occlusion(p_entries: Array[Dictionary], p_camera: Camera3D, p_culled: Array[Dictionary]) -> void:
	var world: World3D = p_camera.get_world_3d()
	if world == null:
		return
	var space: PhysicsDirectSpaceState3D = world.direct_space_state
	if space == null:
		return
	var cam_origin: Vector3 = p_camera.global_position
	var to_remove: Array[Dictionary] = []
	for e in p_entries:
		var corners: Array[Vector3] = e["corners"] as Array[Vector3]
		if corners == null or corners.is_empty():
			continue
		var samples: Array[Vector3] = [(e.aabb as AABB).get_center()]
		samples.append_array(corners)
		var exclude: Array[RID] = _collect_collider_rids(e.node as Node)
		var visible_count: int = 0
		for s in samples:
			var query := PhysicsRayQueryParameters3D.create(cam_origin, s)
			query.exclude = exclude
			query.collide_with_areas = false
			query.collide_with_bodies = true
			var hit: Dictionary = space.intersect_ray(query)
			if hit.is_empty():
				visible_count += 1
		var ratio: float = float(visible_count) / float(samples.size())
		e["visibility"] = ratio
		if ratio <= 0.0:
			e["occluded"] = true
			to_remove.append(e)
		else:
			e["alpha"] = minf(e.get("alpha", 1.0), 0.25 + 0.75 * ratio)
	for e in to_remove:
		p_entries.erase(e)
		p_culled.append(e)


# 收集节点自身、全部祖先与子孙中的碰撞体 RID（用于射线排除自身）
func _collect_collider_rids(p_node: Node) -> Array[RID]:
	var rids: Array[RID] = []
	var cur: Node = p_node
	while cur != null:
		if cur is CollisionObject3D:
			rids.append((cur as CollisionObject3D).get_rid())
		cur = cur.get_parent()
	_collect_collider_rids_recursive(p_node, rids)
	return rids


func _collect_collider_rids_recursive(p_node: Node, p_rids: Array[RID]) -> void:
	for child in p_node.get_children():
		if child is CollisionObject3D:
			p_rids.append((child as CollisionObject3D).get_rid())
		_collect_collider_rids_recursive(child, p_rids)


# --- Private: ID 与颜色 ---

# --- 重名消歧：同名节点生成"父/自身"形式的显示名 ---

# 同名组内按"祖先链后缀"消歧：优先 2 层（父/自身），
# 仍冲突则向上扩展（祖父/父/自身...），最多 MAX_DISPLAY_DEPTH 层
func _assign_display_names(p_entries: Array[Dictionary]) -> void:
	var groups: Dictionary = {}
	for e in p_entries:
		var n: String = String(e.get("name", ""))
		if n.is_empty():
			continue
		if not groups.has(n):
			groups[n] = []
		(groups[n] as Array).append(e)
	for n in groups:
		var group: Array = groups[n]
		if group.size() <= 1:
			(group[0] as Dictionary)["display_name"] = n
			continue
		# 同名组：构建祖先链（自身 → 父 → 祖父 ...）
		var chains: Array[PackedStringArray] = []
		for e in group:
			chains.append(_ancestor_chain(e["node"] as Node, MAX_DISPLAY_DEPTH))
		var depth: int = 2
		while depth <= MAX_DISPLAY_DEPTH and not _chains_unique(chains, depth):
			depth += 1
		for i in group.size():
			var suffix: PackedStringArray = _last_n(chains[i], min(depth, chains[i].size()))
			(group[i] as Dictionary)["display_name"] = "/".join(suffix)


func _ancestor_chain(p_node: Node, p_max: int) -> PackedStringArray:
	var names: PackedStringArray = []
	var cur: Node = p_node
	var depth: int = 0
	while cur != null and depth < p_max:
		names.append(String(cur.name))
		cur = cur.get_parent()
		depth += 1
	return names


func _chains_unique(p_chains: Array[PackedStringArray], p_depth: int) -> bool:
	var seen: Dictionary = {}
	for ch in p_chains:
		var suffix: PackedStringArray = _last_n(ch, p_depth)
		var key: String = "/".join(suffix)
		if seen.has(key):
			return false
		seen[key] = true
	return true


func _last_n(p_chain: PackedStringArray, p_n: int) -> PackedStringArray:
	var start: int = maxi(p_chain.size() - p_n, 0)
	var result: PackedStringArray = []
	for i in range(start, p_chain.size()):
		result.append(p_chain[i])
	return result


# 稳定 ID：按节点路径排序后分配（A-Z → a-z → AA...），同时记录颜色索引
func _assign_ids(p_entries: Array[Dictionary]) -> void:
	var sorted: Array[Dictionary] = p_entries.duplicate()
	sorted.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["path"]) < str(b["path"]))
	for i in sorted.size():
		sorted[i]["id"] = _id_for_index(i)
		sorted[i]["color_index"] = i


func _id_for_index(p_index: int) -> String:
	if p_index < 26:
		return String.chr(65 + p_index)
	if p_index < 52:
		return String.chr(97 + p_index - 26)
	return _id_for_index((p_index - 52) / 26) + _id_for_index((p_index - 52) % 26)


# 黄金角 HSV 色板：相邻 ID 色相差异最大化
func _apply_colors(p_entries: Array[Dictionary]) -> void:
	for e in p_entries:
		var hue: float = fmod(float(e.get("color_index", 0)) * 0.618034, 1.0)
		var c: Color = Color.from_hsv(hue, 0.9, 1.0)
		var alpha: float = e.get("alpha", 1.0)
		e["color"] = Color(c.r, c.g, c.b, alpha)


# --- Private: Mask 模式（实例 ID 缓冲渲染 + 像素统计 + overlay） ---

# 为每个可标注几何节点创建代理（共享 mesh/transform，替换 ID 材质），挂到离屏世界
func _build_proxy_tree(p_entries: Array[Dictionary]) -> Node3D:
	var proxy_root := Node3D.new()
	proxy_root.name = "AIIDProxyRoot"
	for i in p_entries.size():
		var src: Node3D = p_entries[i].node
		var proxy := _make_proxy(src)
		if proxy == null:
			continue
		proxy.transform = src.global_transform  # proxy_root 在原点，直接用全局变换
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_color = _encode_id_color(i + 1)  # ID 0 保留给背景
		mat.disable_fog = true
		proxy.material_override = mat
		proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		proxy_root.add_child(proxy)
		p_entries[i]["instance_id"] = i + 1
	return proxy_root


# 第一版仅支持 MeshInstance3D，其余返回 null（走 AABB 兜底）
func _make_proxy(p_src: Node3D) -> GeometryInstance3D:
	if p_src is MeshInstance3D and (p_src as MeshInstance3D).mesh != null:
		var p := MeshInstance3D.new()
		p.mesh = (p_src as MeshInstance3D).mesh  # 共享引用，只读，无复制开销
		return p
	return null


# 间隔 4 容错编码：回读值落在 [4k, 4k+3] 均解码为 k，±1（含 ±2）误差免疫。
# 容量 6bit × 2 通道 = 12bit = 4095 节点。
func _encode_id_color(p_id: int) -> Color:
	var lo := (p_id & 0x3F) * 4 + 2   # 2,6,10...254
	var hi := ((p_id >> 6) & 0x3F) * 4 + 2
	return Color(lo / 255.0, hi / 255.0, 0.0)


func _decode_id(p_r: int, p_g: int) -> int:
	if p_r == 0 and p_g == 0:
		return 0  # 背景
	return (p_r >> 2) | ((p_g >> 2) << 6)


# 创建离屏 ID 渲染视口：独立 World3D、纯黑背景、Linear tonemap、无 AA/后处理
func _create_id_viewport(p_size: Vector2i, p_editor_cam: Camera3D) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = "AIIDViewport"
	vp.size = p_size
	vp.own_world_3d = true
	vp.world_3d = World3D.new()
	# --- 颜色空间锚定：保证 get_image() 回读为 sRGB 8bit ---
	vp.use_hdr_2d = false
	# --- 防 ID 色污染：全部显式关闭 ---
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	vp.use_taa = false
	vp.use_debanding = false
	vp.use_occlusion_culling = false
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.render_target_clear_mode = SubViewport.CLEAR_MODE_ALWAYS
	# --- 独立 Environment：纯黑背景 + Linear tonemap + 无后处理 ---
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = false
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	env.ssao_enabled = false
	env.ssil_enabled = false
	env.ssr_enabled = false
	env.sdfgi_enabled = false
	vp.world_3d.environment = env
	# --- 克隆相机（参数 + 变换立即拷贝，防编辑器 override 相机跨帧失效） ---
	var cam := Camera3D.new()
	cam.projection = p_editor_cam.projection
	cam.fov = p_editor_cam.fov
	cam.size = p_editor_cam.size
	cam.frustum_offset = p_editor_cam.frustum_offset
	cam.near = p_editor_cam.near
	cam.far = p_editor_cam.far
	cam.h_offset = p_editor_cam.h_offset
	cam.v_offset = p_editor_cam.v_offset
	cam.keep_aspect = p_editor_cam.keep_aspect
	cam.global_transform = p_editor_cam.global_transform
	vp.add_child(cam)
	cam.current = true
	return vp


# 执行 mask 渲染主链路。返回 {overlay: Image, stats: Dictionary}；失败返回 {}（调用方降级 box）
func _run_mask_pass(p_entries: Array[Dictionary], p_camera: Camera3D, p_size: Vector2) -> Dictionary:
	var proxy_root: Node3D = _build_proxy_tree(p_entries)
	if proxy_root.get_child_count() == 0:
		proxy_root.free()
		return {}
	var host := Control.new()
	host.name = "AIMaskHost"
	host.mouse_filter = Control.MOUSE_FILTER_IGNORE
	EditorInterface.get_base_control().add_child(host)
	var vp: SubViewport = _create_id_viewport(Vector2i(p_size), p_camera)
	host.add_child(vp)
	vp.add_child(proxy_root)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var id_img: Image = vp.get_texture().get_image()
	vp.queue_free()
	host.queue_free()
	if id_img == null:
		return {}
	# 防御性颜色空间处理：默认 use_hdr_2d=false 回读 sRGB 8bit；若为 HDR 线性格式先转 sRGB
	if id_img.get_format() in [Image.FORMAT_RGBAH, Image.FORMAT_RGBAF, Image.FORMAT_RGBH, Image.FORMAT_RGBF]:
		id_img.convert(Image.FORMAT_RGBA8)
		id_img.linear_to_srgb()
	id_img.convert(Image.FORMAT_RGB8)
	var stats: Dictionary = _analyze_id_image(id_img)
	if stats.is_empty():
		return {}
	# 统计写回 entries（pixels / centroid / screen_ratio）
	var total_px: int = maxi(id_img.get_width() * id_img.get_height(), 1)
	for e in p_entries:
		var iid: int = e.get("instance_id", 0)
		var st: Dictionary = stats.get(iid, {})
		var count: int = st.get("count", 0)
		e["pixels"] = count
		e["screen_ratio"] = float(count) / float(total_px)
		if count > 0:
			e["centroid"] = _pick_label_anchor(st, id_img, iid)
		else:
			e["centroid"] = _point_anchor(e)  # 点状/无像素节点：锚定投影中心
	# 展示色映射（ID -> 半透明填充色）
	var id_colors: Dictionary = {}
	for e in p_entries:
		id_colors[e.get("instance_id", 0)] = e.get("color", Color.YELLOW)
	var overlay: Image = _build_mask_overlay(id_img, id_colors)
	if overlay == null:
		return {}
	return {"overlay": overlay, "stats": stats}


# 解码 ID 图并统计每个节点的像素数 / bbox / 质心累加
func _analyze_id_image(p_img: Image) -> Dictionary:
	var data := p_img.get_data()  # RGB8: 3 bytes/px
	var w := p_img.get_width()
	var h := p_img.get_height()
	var stats := {}
	for y in h:
		var row := y * w * 3
		for x in w:
			var o := row + x * 3
			var id := _decode_id(data[o], data[o + 1])
			if id == 0:
				continue
			var s: Dictionary = stats.get(id, {
				"count": 0, "min_x": x, "min_y": y,
				"max_x": x, "max_y": y, "sum_x": 0, "sum_y": 0})
			s.count += 1
			s.sum_x += x; s.sum_y += y
			s.min_x = mini(s.min_x, x); s.max_x = maxi(s.max_x, x)
			s.min_y = mini(s.min_y, y); s.max_y = maxi(s.max_y, y)
			stats[id] = s
	return stats


# 生成 RGBA overlay：半透明填充 + 2px 不透明轮廓（其余像素全透明）
func _build_mask_overlay(p_id_img: Image, p_id_colors: Dictionary) -> Image:
	var w := p_id_img.get_width()
	var h := p_id_img.get_height()
	var src := p_id_img.get_data()
	var out := PackedByteArray()
	out.resize(w * h * 4)  # RGBA8，初始全 0（透明）
	# 第一遍：半透明填充
	for y in h:
		var row := y * w * 3
		var orow := y * w * 4
		for x in w:
			var id := _decode_id(src[row + x * 3], src[row + x * 3 + 1])
			if id == 0 or not p_id_colors.has(id):
				continue
			var c: Color = p_id_colors[id]
			var o := orow + x * 4
			out[o] = int(c.r8); out[o + 1] = int(c.g8)
			out[o + 2] = int(c.b8); out[o + 3] = MASK_FILL_ALPHA
	# 第二遍：轮廓（与右/下邻居 ID 不同 → 双方描边）
	for y in h:
		for x in w:
			var o3 := (y * w + x) * 3
			var id := _decode_id(src[o3], src[o3 + 1])
			if x + 1 < w:
				var nid := _decode_id(src[o3 + 3], src[o3 + 4])
				if nid != id:
					_stamp_outline(out, w, h, x, y, id, nid, p_id_colors)
					_stamp_outline(out, w, h, x + 1, y, nid, id, p_id_colors)
			if y + 1 < h:
				var o3b := o3 + w * 3
				var nid2 := _decode_id(src[o3b], src[o3b + 1])
				if nid2 != id:
					_stamp_outline(out, w, h, x, y, id, nid2, p_id_colors)
					_stamp_outline(out, w, h, x, y + 1, nid2, id, p_id_colors)
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, out)


# 在该像素以"自身 ID 色"画 2px 不透明轮廓；自身为背景则用邻居色
func _stamp_outline(p_out: PackedByteArray, p_w: int, p_h: int,
		p_x: int, p_y: int, p_self: int, p_other: int, p_colors: Dictionary) -> void:
	var use_id := p_self if (p_self != 0 and p_colors.has(p_self)) else p_other
	if use_id == 0 or not p_colors.has(use_id):
		return
	var c: Color = p_colors[use_id]
	for dy in 2:
		for dx in 2:
			var px := p_x + dx; var py := p_y + dy
			if px >= p_w or py >= p_h:
				continue
			var o := (py * p_w + px) * 4
			p_out[o] = c.r8; p_out[o + 1] = c.g8
			p_out[o + 2] = c.b8; p_out[o + 3] = MASK_OUTLINE_ALPHA


# 标签锚点：首选 mask 质心（质心像素确属本 ID）；否则退化为统计 bbox 中心
func _pick_label_anchor(p_stats: Dictionary, p_id_img: Image, p_id: int) -> Vector2:
	var count: int = p_stats.get("count", 0)
	if count <= 0:
		return Vector2.ZERO
	var cx: int = int(p_stats.get("sum_x", 0) / count)
	var cy: int = int(p_stats.get("sum_y", 0) / count)
	var w: int = p_id_img.get_width()
	var h: int = p_id_img.get_height()
	if cx >= 0 and cx < w and cy >= 0 and cy < h:
		var data := p_id_img.get_data()
		var o := (cy * w + cx) * 3
		if _decode_id(data[o], data[o + 1]) == p_id:
			return Vector2(cx, cy)
	# 退化：统计 bbox 中心
	var bmin := Vector2(p_stats.get("min_x", cx), p_stats.get("min_y", cy))
	var bmax := Vector2(p_stats.get("max_x", cx), p_stats.get("max_y", cy))
	return (bmin + bmax) * 0.5


# 点状节点/无像素节点：锚定投影 rect 中心（用于图标与标签）
func _point_anchor(p_entry: Dictionary) -> Vector2:
	var r: Rect2 = p_entry.get("rect", Rect2())
	if r.size.x > 0.0 and r.size.y > 0.0:
		return r.get_center()
	return Vector2.ZERO


# --- Private: 通用辅助 ---

func _aabb_corners(p_aabb: AABB) -> Array[Vector3]:
	var p := p_aabb.position
	var s := p_aabb.size
	return [
		p,
		p + Vector3(s.x, 0, 0),
		p + Vector3(0, s.y, 0),
		p + Vector3(0, 0, s.z),
		p + Vector3(s.x, s.y, 0),
		p + Vector3(s.x, 0, s.z),
		p + Vector3(0, s.y, s.z),
		p + Vector3(s.x, s.y, s.z),
	]


## 构建 AnnotationOverlay 绘制项（mask 模式返回纹理项，box 模式返回矩形项）
func _build_draw_items(p_entries: Array[Dictionary], p_overlay_img: Image, p_mask_used: bool) -> Array:
	if p_mask_used and p_overlay_img != null:
		var labels: Array = []
		for e in p_entries:
			var px: int = e.get("pixels", 0)
			var is_point: bool = e.get("point", false)
			if px <= 0 and not is_point:
				continue  # 完全遮挡的非点状节点不画
			labels.append({
				"id": e.id,
				"name": e.get("display_name", e.name),
				"anchor": e.get("centroid", Vector2.ZERO),
				"color": e.get("color", Color.YELLOW),
				"icon": is_point,  # 点状节点画十字图标（无 mask 时也能被看见）
			})
		return [{"texture": ImageTexture.create_from_image(p_overlay_img), "labels": labels}]
	# box 模式：现有逻辑
	var items: Array = []
	for e in p_entries:
		items.append({
			"rect": e.rect,
			"id": e.id,
			"name": e.get("display_name", e.name),
			"color": e.get("color", Color.YELLOW),
		})
	return items


# 裁剪路径为场景相对路径（含根节点名），如 "Level/Ground/Mesh"
func _short_path(p_path: String, p_root_path: String) -> String:
	var root_name: String = p_root_path.get_file() if p_root_path.contains("/") else p_root_path
	root_name = p_root_path.split("/")[-1]
	if p_path.begins_with(p_root_path):
		var rel: String = p_path.substr(p_root_path.length()).trim_prefix("/")
		return root_name + "/" + rel if not rel.is_empty() else root_name
	return p_path


func _build_legend(p_entries: Array[Dictionary], p_out_of_view: Array[Dictionary],
		p_screen_size: Vector2, p_root_path: String,
		p_verbose: bool = true, p_mask_used: bool = false, p_mask_note: String = "") -> String:
	var lines: PackedStringArray = []
	lines.append("=== Annotated 3D Scene Screenshot ===")
	lines.append("Viewport: 3D | Resolution: %dx%d" % [int(p_screen_size.x), int(p_screen_size.y)])
	if p_verbose:
		if p_mask_used:
			lines.append("Annotation: pixel-exact instance masks (ID buffer). pixels = exact visible pixels; occluded nodes show 0 px.")
			lines.append("Mask overlay = translucent fill + 2px outline; labels anchored at mask centroid; point nodes (cameras/lights/markers) = cross icons.")
		else:
			lines.append("Annotation: AABB boxes. Boxes = screen projection of node bounds; labels = node ID; colors match legend hex.")
			lines.append("Huge boxes (over 55% of screen) are drawn as corner marks only. Opacity fades with distance/occlusion.")
		if not p_mask_note.is_empty():
			lines.append("Note: %s" % p_mask_note)
	lines.append("")
	lines.append("Legend (ID -> node) [nearest first]:")
	for e in p_entries:
		var short_path: String = _short_path(str(e.path), p_root_path)
		var color_hex: String = (e.color as Color).to_html(false)
		var s: Vector3 = (e.aabb as AABB).size
		var line := "  %s -> %s (%s) | %s | dist %.1fm | size %.2fx%.2fx%.2f" % [
			e.id, e.get("display_name", e.name), e.class, short_path, e.dist, s.x, s.y, s.z]
		if e.has("pixels"):
			var pos: Vector3 = (e.aabb as AABB).get_center()
			line += " | pos (%.2f, %.2f, %.2f)" % [pos.x, pos.y, pos.z]
			if e.pixels > 0:
				line += " | pixels %d (%.2f%% of screen)" % [e.pixels, float(e.screen_ratio) * 100.0]
			elif e.get("point", false):
				line += " | pixels 0 (point node, cross icon)"
			else:
				line += " | pixels 0 (fully occluded)"
		elif e.get("point", false):
			line += " | point node"
		line += " | #%s" % color_hex
		lines.append(line)
	
	# 未标注节点（视锥外 / 超量截断 / box 模式完全遮挡）——仅 verbose 输出
	if p_verbose and not p_out_of_view.is_empty():
		lines.append("")
		lines.append("Not annotated (outside frustum / truncated by max_nodes / fully occluded):")
		for e in p_out_of_view:
			var reason: String = "fully occluded" if e.get("occluded", false) else "out of view"
			lines.append("  - %s (%s) | %s | %s" % [e.name, e.class, _short_path(str(e.path), p_root_path), reason])
	
	# Notes——仅 verbose 输出
	if p_verbose:
		lines.append("")
		lines.append("Notes:")
		if p_mask_used:
			lines.append("  - Mask covers MeshInstance3D nodes only; other node types fall back to AABB boxes.")
			lines.append("  - Point nodes (cameras/lights/markers/areas) drawn as cross icons with labels.")
			lines.append("  - Vertex-animated shaders (water/flags) show static masks; transparent materials are treated as opaque.")
		else:
			lines.append("  - Point-like nodes (cameras/lights) use 0.01m boxes.")
			lines.append("  - Occlusion is raycast-based (center + 8 corners); requires collision bodies, otherwise all nodes are shown.")
		lines.append("  - Use exclude_nodes to hide bulky occluders (e.g. [\"Walls\"]) for cleaner results.")
		lines.append("  - Boxes project the actual rotated AABB corners, so rotated objects stay tightly fitted.")
	return "\n".join(lines)
