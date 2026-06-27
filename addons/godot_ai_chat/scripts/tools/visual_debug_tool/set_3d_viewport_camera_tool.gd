@tool
extends AiTool

## 设置 3D 编辑器视窗的相机视角
##
## 通过控制 3D 编辑器视口的相机位置、FOV 等参数，
## 让 Agent 能从多角度检查场景内容。配合截图工具即可实现多视角 Debug。

# --- Built-in Functions ---

func _init() -> void:
	tool_name = "set_3d_viewport_camera"
	tool_description = "Controls the 3D editor viewport camera. Supports setting position + look-at target, FOV, and projection mode."
	security_level = SecurityLevel.NONE


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
			"position": {
				"type": "array",
				"description": "Camera position as [x, y, z]. Use together with 'look_at' to specify where the camera stands and what it looks at.",
				"items": {"type": "number"}
			},
			"look_at": {
				"type": "array",
				"description": "Target point for the camera to look at [x, y, z]. Must be used together with 'position'. The camera will be placed at 'position' and oriented towards this target.",
				"items": {"type": "number"}
			},
			"fov": {
				"type": "number",
				"description": "ADVANCED: Field of view in degrees. Only when you need to zoom in/out. Normally leave unset."
			},
			"projection": {
				"type": "string",
				"description": "ADVANCED: Projection mode: 'perspective' or 'orthogonal'. Only when switching projection type. Normally leave unset.",
				"enum": ["perspective", "orthogonal"]
			}
		},
		"required": ["position", "look_at"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Editor only tool.")
	
	# 校验：至少需要一个相机操作参数
	var has_position: bool = p_args.has("position") and not p_args["position"] == null
	var has_look_at: bool = p_args.has("look_at") and not p_args["look_at"] == null
	var has_fov: bool = p_args.has("fov") and not p_args["fov"] == null
	var has_projection: bool = p_args.has("projection") and not p_args["projection"] == null
	
	if not (has_position or has_look_at or has_fov or has_projection):
		return ToolResult.fail("At least one parameter is required. Use 'position' + 'look_at' together to set camera view. Example: position: [0, 5, 10], look_at: [0, 0, 0]")
	
	# 校验：look_at 必须搭配 position
	if has_look_at and not has_position:
		return ToolResult.fail("'look_at' must be used together with 'position'. The camera stays in place if only 'look_at' is provided. Example: position: [0, 5, 10], look_at: [0, 0, 0]")
	
	var viewport_index: int = p_args.get("viewport_index", 0)
	
	EditorInterface.set_main_screen_editor("3D")
	var viewport: SubViewport = EditorInterface.get_editor_viewport_3d(viewport_index)
	if not viewport:
		return ToolResult.fail("No 3D viewport found at index %d." % viewport_index)
	
	var camera: Camera3D = viewport.get_camera_3d()
	if not camera:
		return ToolResult.fail("No active Camera3D in viewport %d." % viewport_index)
	
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
				return ToolResult.fail("Invalid projection mode: '%s'. Use 'perspective' or 'orthogonal'." % proj)
	
	# 2. 设置 FOV
	if p_args.has("fov") and not p_args["fov"] == null:
		var fov_val: float = float(p_args["fov"])
		if fov_val <= 0 or fov_val > 179:
			return ToolResult.fail("FOV must be in range (0, 179], got %f." % fov_val)
		camera.fov = fov_val
		changes.append("fov → %.1f°" % fov_val)
	
	# 3. 设置位置
	if p_args.has("position") and not p_args["position"] == null:
		var pos: Array = p_args["position"]
		if pos.size() < 3:
			return ToolResult.fail("Position requires 3 values [x, y, z], got %d." % pos.size())
		camera.global_position = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		changes.append("position → (%.2f, %.2f, %.2f)" % [float(pos[0]), float(pos[1]), float(pos[2])])
	
	# 4. 设置 look_at（在 position 之后设置）
	if p_args.has("look_at") and not p_args["look_at"] == null:
		var target: Array = p_args["look_at"]
		if target.size() < 3:
			return ToolResult.fail("look_at requires 3 values [x, y, z], got %d." % target.size())
		var target_pos := Vector3(float(target[0]), float(target[1]), float(target[2]))
		var dir := target_pos - camera.global_position
		var up := Vector3.UP
		if abs(dir.normalized().dot(up)) > 0.9999:
			up = Vector3.FORWARD
		camera.look_at(target_pos, up)
		changes.append("look_at → (%.2f, %.2f, %.2f)" % [float(target[0]), float(target[1]), float(target[2])])
	
	if changes.is_empty():
		return ToolResult.ok("No parameters provided. Camera unchanged. Current position: %s, rotation: %s, fov: %.1f°" % [str(camera.global_position), str(camera.global_rotation_degrees), camera.fov])
	
	return ToolResult.ok("3D viewport camera updated (viewport %d): %s" % [viewport_index, ", ".join(changes)])
