@tool
extends AiTool

## 设置 / 查询 3D 编辑器视窗的相机视角
##
## 支持四类操作：
##   1. 绝对设置：position + look_at（成对使用，或单独 look_at 原地转头）、
##      fov、projection、orthogonal_size（正交缩放）
##   2. 增量操作：orbit（绕目标旋转）、distance/distance_by（沿视线推拉）、
##      move_by（世界轴平移）、move_by_local（相机局部平移）——
##      执行后返回最终绝对状态供 AI 感知落点
##   3. 查询模式：query = true 只读当前视角（含场景名），不做任何修改
##
## 说明：AI 复现某视角可直接重放历史调用参数（上下文即可）；
##       增量操作后的绝对状态由工具返回，避免 AI 手动累加推算。

# --- Static 缓存：跨调用记住最近一次 look_at 目标（orbit/distance 的环绕中心） ---
static var _last_look_at: Vector3 = Vector3.ZERO
static var _has_look_at: bool = false

# --- Built-in Functions ---

func _init() -> void:
	tool_name = "set_3d_viewport_camera"
	tool_description = "Sets or queries the 3D editor viewport camera."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"viewport_index": {
				"type": "integer",
				"description": "ADVANCED: 3D viewport index (0-3). Only specify when targeting a non-default viewport. Default 0 is the main perspective viewport.",
				"default": 0
			},
			"query": {
				"type": "boolean",
				"description": "Query-only mode: return the current camera state (scene/position/orientation/fov/projection) WITHOUT modifying anything. Use this to perceive the current view before planning."
			},
			"position": {
				"type": "array",
				"description": "Camera position as [x, y, z]. Use together with 'look_at' to specify where the camera stands and what it looks at.",
				"items": {"type": "number"}
			},
			"look_at": {
				"type": "array",
				"description": "Target point for the camera to look at [x, y, z]. Can be used alone (rotate in place) or with 'position'.",
				"items": {"type": "number"}
			},
			"fov": {
				"type": "number",
				"description": "ADVANCED: Field of view in degrees (perspective only). Range (0, 179]. Normally leave unset.",
			},
			"projection": {
				"type": "string",
				"description": "ADVANCED: Projection mode: 'perspective' or 'orthogonal'. Only when switching projection type. Normally leave unset.",
				"enum": ["perspective", "orthogonal"]
			},
			"orthogonal_size": {
				"type": "number",
				"description": "ADVANCED: Orthogonal viewport size (Camera3D.size) - controls zoom in ortho mode. Only effective when projection is orthogonal. Default 10.0."
			},
			"orbit": {
				"type": "object",
				"properties": {
					"yaw": {"type": "number", "description": "Rotate around the world Y axis by delta degrees (horizontal orbit, clockwise from above)."},
					"pitch": {"type": "number", "description": "Rotate around the camera's right axis by delta degrees (positive tilts up)."}
				},
				"description": "Rotate the camera around the look_at target (or the last remembered target) by delta angles."
			},
			"distance": {
				"type": "number",
				"description": "Move the camera along its view direction to this absolute distance from the look_at target (zoom). Must be > 0."
			},
			"distance_by": {
				"type": "number",
				"description": "Move the camera along its view direction by this relative amount (positive = closer to target)."
			},
			"move_by": {
				"type": "array",
				"description": "Translate the camera by this WORLD-axis offset [x, y, z] (orientation unchanged).",
				"items": {"type": "number"}
			},
			"move_by_local": {
				"type": "array",
				"description": "Translate the camera by this CAMERA-LOCAL offset [right, up, forward] (e.g. [2,0,0] = 2m to the camera's right, [0,0,1] = 1m forward). Use 'move_by' for world-axis translation.",
				"items": {"type": "number"}
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")
	
	var viewport_index: int = p_args.get("viewport_index", 0)
	EditorInterface.set_main_screen_editor("3D")
	var viewport: SubViewport = EditorInterface.get_editor_viewport_3d(viewport_index)
	if not viewport:
		return ToolResult.fail("Error: no 3D viewport found at index %d." % viewport_index)
	var camera: Camera3D = viewport.get_camera_3d()
	if not camera:
		return ToolResult.fail("Error: no active Camera3D in viewport %d." % viewport_index)
	
	# --- query 模式：只读当前视角 ---
	if bool(p_args.get("query", false)):
		return ToolResult.ok(_format_state(camera, viewport_index))
	
	# --- 校验：至少一个操作参数 ---
	var has_position: bool = p_args.has("position") and not p_args["position"] == null
	var has_look_at: bool = p_args.has("look_at") and not p_args["look_at"] == null
	var has_fov: bool = p_args.has("fov") and not p_args["fov"] == null
	var has_projection: bool = p_args.has("projection") and not p_args["projection"] == null
	var has_ortho_size: bool = p_args.has("orthogonal_size") and not p_args["orthogonal_size"] == null
	var has_orbit: bool = p_args.has("orbit") and not p_args["orbit"] == null
	var has_distance: bool = p_args.has("distance") and not p_args["distance"] == null
	var has_distance_by: bool = p_args.has("distance_by") and not p_args["distance_by"] == null
	var has_move_by: bool = p_args.has("move_by") and not p_args["move_by"] == null
	var has_move_by_local: bool = p_args.has("move_by_local") and not p_args["move_by_local"] == null
	
	if not (has_position or has_look_at or has_fov or has_projection or has_ortho_size
			or has_orbit or has_distance or has_distance_by or has_move_by or has_move_by_local):
		return ToolResult.fail("Error: at least one operation is required. Use 'query': true to read the current view. "
			+ "Example: {\"position\": [0, 5, 10], \"look_at\": [0, 0, 0]}")
	
	var changes: Array[String] = []
	var used_orbit: bool = false
	var used_dist: bool = false
	
	# --- 1. 投影模式 ---
	if has_projection:
		var proj: String = p_args["projection"]
		match proj:
			"perspective":
				camera.projection = Camera3D.PROJECTION_PERSPECTIVE
				changes.append("projection → perspective")
			"orthogonal":
				camera.projection = Camera3D.PROJECTION_ORTHOGONAL
				changes.append("projection → orthogonal")
			_:
				return ToolResult.fail("Error: invalid projection mode: '%s'. Use 'perspective' or 'orthogonal'." % proj)
	
	# --- 2. 正交缩放（仅正交投影生效） ---
	if has_ortho_size:
		var os: float = float(p_args["orthogonal_size"])
		if os <= 0.0:
			return ToolResult.fail("Error: orthogonal_size must be > 0, got %f." % os)
		camera.size = os
		var note: String = "" if camera.projection == Camera3D.PROJECTION_ORTHOGONAL else " (only effective in ortho mode)"
		changes.append("orthogonal_size → %.2f%s" % [os, note])
	
	# --- 3. FOV（透视） ---
	if has_fov:
		var fov_val: float = float(p_args["fov"])
		if fov_val <= 0 or fov_val > 179:
			return ToolResult.fail("Error: FOV must be in range (0, 179], got %f." % fov_val)
		camera.fov = fov_val
		changes.append("fov → %.1f°" % fov_val)
	
	# --- 4. 绝对位置 ---
	if has_position:
		var pos: Array = p_args["position"]
		if pos.size() < 3:
			return ToolResult.fail("Error: position requires 3 values [x, y, z], got %d." % pos.size())
		camera.global_position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		changes.append("position → (%.2f, %.2f, %.2f)" % [float(pos[0]), float(pos[1]), float(pos[2])])
	
	# --- 5. 相对平移（世界轴 / 相机局部轴） ---
	if has_move_by:
		var mb: Array = p_args["move_by"]
		if mb.size() < 3:
			return ToolResult.fail("Error: move_by requires 3 values [x, y, z], got %d." % mb.size())
		var off := Vector3(float(mb[0]), float(mb[1]), float(mb[2]))
		camera.global_position += off
		changes.append("move_by → (%.2f, %.2f, %.2f)" % [off.x, off.y, off.z])
	
	if has_move_by_local:
		var ml: Array = p_args["move_by_local"]
		if ml.size() < 3:
			return ToolResult.fail("Error: move_by_local requires 3 values [right, up, forward], got %d." % ml.size())
		var loff := Vector3(float(ml[0]), float(ml[1]), float(ml[2]))
		camera.global_position += camera.global_transform.basis * loff
		changes.append("move_by_local → (%.2f, %.2f, %.2f)" % [loff.x, loff.y, loff.z])
	
	# --- 6. 环绕中心解析（本次 look_at 优先，其次缓存，最后沿视线前推 10m 推断） ---
	var center: Vector3 = _resolve_center(p_args, camera)
	
	# --- 7. orbit：绕中心旋转 ---
	if has_orbit:
		var ob: Dictionary = p_args["orbit"]
		var yaw_d: float = float(ob.get("yaw", 0.0))
		var pitch_d: float = float(ob.get("pitch", 0.0))
		if yaw_d == 0.0 and pitch_d == 0.0:
			return ToolResult.fail("Error: orbit requires 'yaw' and/or 'pitch' (degrees).")
		var offset: Vector3 = camera.global_position - center
		if yaw_d != 0.0:
			offset = offset.rotated(Vector3.UP, deg_to_rad(yaw_d))
		if pitch_d != 0.0:
			var view_dir: Vector3 = -offset.normalized()  # 相机指向中心
			var right: Vector3 = view_dir.cross(Vector3.UP).normalized()
			if right.length() < 0.001:
				right = Vector3.RIGHT
			offset = offset.rotated(right, deg_to_rad(pitch_d))
		camera.global_position = center + offset
		changes.append("orbit → yaw %+.1f°, pitch %+.1f° around (%.1f, %.1f, %.1f)"
			% [yaw_d, pitch_d, center.x, center.y, center.z])
		used_orbit = true
	
	# --- 8. distance / distance_by：沿视线推拉 ---
	if has_distance:
		var dist: float = float(p_args["distance"])
		if dist <= 0.0:
			return ToolResult.fail("Error: distance must be > 0, got %f." % dist)
		var dir: Vector3 = (center - camera.global_position).normalized()
		camera.global_position = center - dir * dist
		changes.append("distance → %.2fm" % dist)
		used_dist = true
	
	if has_distance_by:
		var delta: float = float(p_args["distance_by"])
		var cur_d: float = camera.global_position.distance_to(center)
		var new_d: float = maxf(cur_d + delta, 0.1)
		var dir2: Vector3 = (center - camera.global_position).normalized()
		camera.global_position = center - dir2 * new_d
		changes.append("distance_by → %+.2fm (dist %.2f → %.2f)" % [delta, cur_d, new_d])
		used_dist = true
	
	# --- 9. 朝向收尾：显式 look_at 优先；否则 orbit/distance 看向中心 ---
	if has_look_at:
		var target: Array = p_args["look_at"]
		if target.size() < 3:
			return ToolResult.fail("Error: look_at requires 3 values [x, y, z], got %d." % target.size())
		var target_pos := Vector3(float(target[0]), float(target[1]), float(target[2]))
		_look_at_target(camera, target_pos)
		_last_look_at = target_pos
		_has_look_at = true
		changes.append("look_at → (%.2f, %.2f, %.2f)" % [target_pos.x, target_pos.y, target_pos.z])
	elif used_orbit or used_dist:
		_look_at_target(camera, _last_look_at)
		_has_look_at = true
		changes.append("oriented → (%.2f, %.2f, %.2f)" % [_last_look_at.x, _last_look_at.y, _last_look_at.z])
	
	if changes.is_empty():
		return ToolResult.ok(_format_state(camera, viewport_index))
	
	var result: String = "3D viewport camera updated (viewport %d): %s" % [viewport_index, ", ".join(changes)]
	# 增量操作（orbit/distance/distance_by/move_by/move_by_local）后返回最终绝对状态，供 AI 感知落点
	if used_orbit or used_dist or has_move_by or has_move_by_local:
		result += "\n" + _format_state(camera, viewport_index)
	return ToolResult.ok(result)


# --- Private Functions ---

# 解析环绕中心：本次 look_at 优先，其次静态缓存，最后沿当前视线前推 10m 推断
func _resolve_center(p_args: Dictionary, p_camera: Camera3D) -> Vector3:
	if p_args.has("look_at") and not p_args["look_at"] == null:
		var t: Array = p_args["look_at"]
		var c := Vector3(float(t[0]), float(t[1]), float(t[2]))
		_last_look_at = c
		_has_look_at = true
		return c
	if _has_look_at:
		return _last_look_at
	var fwd: Vector3 = -p_camera.global_transform.basis.z
	return p_camera.global_position + fwd * 10.0


# 让相机看向目标，处理极点翻转（up 与视线平行时换 up）
func _look_at_target(p_camera: Camera3D, p_target: Vector3) -> void:
	var dir: Vector3 = p_target - p_camera.global_position
	var up := Vector3.UP
	if abs(dir.normalized().dot(up)) > 0.9999:
		up = Vector3.FORWARD
	p_camera.look_at(p_target, up)


# 计算相机 yaw（绕 Y）与 pitch（俯仰）角（度）
func _camera_angles(p_camera: Camera3D) -> Vector2:
	var fwd: Vector3 = -p_camera.global_transform.basis.z
	var yaw := rad_to_deg(atan2(fwd.x, fwd.z))
	var pitch := rad_to_deg(asin(clampf(fwd.y, -1.0, 1.0)))
	return Vector2(yaw, pitch)


# 格式化当前相机状态（query / 增量操作后返回）
func _format_state(p_camera: Camera3D, p_index: int) -> String:
	var pos: Vector3 = p_camera.global_position
	var angles: Vector2 = _camera_angles(p_camera)
	var fwd: Vector3 = -p_camera.global_transform.basis.z
	var up: Vector3 = p_camera.global_transform.basis.y
	var is_ortho: bool = p_camera.projection == Camera3D.PROJECTION_ORTHOGONAL
	var scene_node: Node = EditorInterface.get_edited_scene_root()
	var scene_name: String = str(scene_node.name) if scene_node != null else "(none)"
	var lines := PackedStringArray()
	lines.append("=== 3D Viewport Camera State (viewport %d) ===" % p_index)
	lines.append("scene: %s" % scene_name)
	lines.append("projection: %s | fov: %.1f° | near: %.2f | far: %.1f%s" % [
		"orthogonal" if is_ortho else "perspective",
		p_camera.fov, p_camera.near, p_camera.far,
		" | ortho_size: %.1f" % p_camera.size if is_ortho else ""])
	lines.append("position: (%.2f, %.2f, %.2f)" % [pos.x, pos.y, pos.z])
	if _has_look_at:
		var d: float = pos.distance_to(_last_look_at)
		lines.append("look_at: (%.2f, %.2f, %.2f) | dist: %.2fm" % [_last_look_at.x, _last_look_at.y, _last_look_at.z, d])
	else:
		lines.append("look_at: (not recorded)")
	lines.append("yaw: %.1f° | pitch: %.1f° | forward: (%.2f, %.2f, %.2f) | up: (%.2f, %.2f, %.2f)" % [
		angles.x, angles.y, fwd.x, fwd.y, fwd.z, up.x, up.y, up.z])
	return "\n".join(lines)
