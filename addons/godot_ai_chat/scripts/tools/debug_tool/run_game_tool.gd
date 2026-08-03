@tool
extends AiTool

func _init() -> void:
	tool_name = "run_game"
	tool_description = "Runs a specific scene in the editor."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"scene_path": {
				"type": "string",
				"description": "Full path of the scene (.tscn) to run."
			}
		},
		"required": ["scene_path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")
	
	var scene_path: String = p_args.get("scene_path", "")
	if scene_path.is_empty():
		return ToolResult.fail("Error: 'scene_path' is required.")
	
	# 路径安全检查（复用 AiTool 基类）
	var safety_err: String = validate_path_safety(scene_path)
	if not safety_err.is_empty():
		return ToolResult.fail(safety_err)
	if not scene_path.ends_with(".tscn"):
		return ToolResult.fail("Error: '%s' is not a .tscn scene file." % scene_path)
	if not FileAccess.file_exists(scene_path):
		return ToolResult.fail("Error: scene file not found: %s" % scene_path)
	
	EditorInterface.play_custom_scene(scene_path)
	
	# 启动是异步子进程，稍候回读真实状态
	await (Engine.get_main_loop() as SceneTree).create_timer(0.4).timeout
	if EditorInterface.is_playing_scene():
		return ToolResult.ok("Game is now running: `%s`" % scene_path)
	return ToolResult.fail("Run dispatched, but game did not enter playing state: %s" % scene_path)
