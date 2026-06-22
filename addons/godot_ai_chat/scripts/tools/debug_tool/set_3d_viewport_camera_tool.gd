@tool
extends AiTool

## 设置 3D 编辑器视窗的相机视角
## 
## 通过控制 3D 编辑器视口的相机位置、旋转、FOV 等参数，
## 让 Agent 能从多角度检查场景内容。配合截图工具即可实现多视角 Debug。

# --- Built-in Functions ---

func _init() -> void:
	tool_name = "set_3d_viewport_camera"
	tool_description = "Controls the 3D editor viewport camera. Supports setting position, rotation, look-at target, FOV, and projection mode."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"viewport_index": {
				"type": "integer",
				"description": "3D viewport index (0-3). Default 0 is the main perspective viewport.",
				"default": 0
			},
			"position": {
				"type": "array",
				"description": "Camera position as [x, y, z]. Optional.",
				"items": {"type": "number"}
			},
			"rotation": {
				"type": "array",
				"description": "Camera rotation as Euler angles in degrees [pitch, yaw, roll]. Optional.",
				"items": {"type": "number"}
			},
			"look_at": {
				"type": "array",
				"description": "Target point for the camera to look at [x, y, z]. If used together with 'position', camera will be placed at 'position' and oriented towards this target.",
				"items": {"type": "number"}
			},
			"fov": {
				"type": "number",
				"description": "Field of view in degrees. Only applies to perspective projection. Optional."
			},
			"projection": {
				"type": "string",
				"description": "Projection mode: 'perspective' or 'orthogonal'. Optional.",
				"enum": ["perspective", "orthogonal"]
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Editor only tool."}
	
	var viewport_index: int = p_args.get("viewport_index", 0)
	
	var viewport: SubViewport = EditorInterface.get_editor_viewport_3d(viewport_index)
	if not viewport:
		return {"success": false, "data": "No 3D viewport found at index %d." % viewport_index}
	
	var camera: Camera3D = viewport.get_camera_3d()
	if not camera:
		return {"success": false, "data": "No active Camera3D in viewport %d." % viewport_index}
	
	var changes: Array[String] = []
	
	# 1. 设置投影模式
	if p_args.has("projection") and not p_args["projection"] == null:
		var proj: String = p_args["projection"]
		match proj:
			"perspective":
				camera.projection = Camera3D.PROJECTION_PERSPECTIVE
				changes.append("projection → perspective")
			"orthogonal":
				camera.projection = Camera3D.PROJECTION_ORTHOGONAL
				changes.append("projection → orthogonal")
			_:
				return {"success": false, "data": "Invalid projection mode: '%s'. Use 'perspective' or 'orthogonal'." % proj}
	
	# 2. 设置 FOV
	if p_args.has("fov") and not p_args["fov"] == null:
		var fov_val: float = float(p_args["fov"])
		if fov_val <= 0 or fov_val > 179:
			return {"success": false, "data": "FOV must be in range (0, 179], got %f." % fov_val}
		camera.fov = fov_val
		changes.append("fov → %.1f°" % fov_val)
	
	# 3. 设置位置
	if p_args.has("position") and not p_args["position"] == null:
		var pos: Array = p_args["position"]
		if pos.size() < 3:
			return {"success": false, "data": "Position requires 3 values [x, y, z], got %d." % pos.size()}
		camera.global_position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		changes.append("position → (%.2f, %.2f, %.2f)" % [float(pos[0]), float(pos[1]), float(pos[2])])
	
	# 4. 设置旋转（欧拉角）
	if p_args.has("rotation") and not p_args["rotation"] == null:
		var rot: Array = p_args["rotation"]
		if rot.size() < 3:
			return {"success": false, "data": "Rotation requires 3 values [pitch, yaw, roll] in degrees, got %d." % rot.size()}
		camera.global_rotation = Vector3(
			deg_to_rad(float(rot[0])),
			deg_to_rad(float(rot[1])),
			deg_to_rad(float(rot[2]))
		)
		changes.append("rotation → [%.1f°, %.1f°, %.1f°]" % [float(rot[0]), float(rot[1]), float(rot[2])])
	
	# 5. 设置 look_at（在 position 之后设置，会覆盖 rotation）
	if p_args.has("look_at") and not p_args["look_at"] == null:
		var target: Array = p_args["look_at"]
		if target.size() < 3:
			return {"success": false, "data": "look_at requires 3 values [x, y, z], got %d." % target.size()}
		var target_pos := Vector3(float(target[0]), float(target[1]), float(target[2]))
		# 如果没有提供 position，保持相机原地
		var dir := target_pos - camera.global_position
		var up := Vector3.UP
		if abs(dir.normalized().dot(up)) > 0.9999:
			up = Vector3.FORWARD
		camera.look_at(target_pos, up)
		
		changes.append("look_at → (%.2f, %.2f, %.2f)" % [float(target[0]), float(target[1]), float(target[2])])
	
	if changes.is_empty():
		return {"success": true, "data": "No parameters provided. Camera unchanged. Current position: %s, rotation: %s, fov: %.1f°" % [str(camera.global_position), str(camera.global_rotation_degrees), camera.fov]}
	
	return {"success": true, "data": "3D viewport camera updated (viewport %d): %s" % [viewport_index, ", ".join(changes)]}
