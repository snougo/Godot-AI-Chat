@tool
extends AiTool


func _init() -> void:
	tool_name = "stop_game"
	tool_description = "Stops the game currently running in the editor."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")
	
	if not EditorInterface.is_playing_scene():
		return ToolResult.ok("No game is currently running — nothing to stop.")
	
	EditorInterface.stop_playing_scene()
	
	# 停止也是异步的，等待状态收敛
	await (Engine.get_main_loop() as SceneTree).create_timer(0.4).timeout
	if EditorInterface.is_playing_scene():
		return ToolResult.fail("Stop dispatched, but the game is still reported as playing.")
	return ToolResult.ok("Game stopped.")
