@tool
extends AiTool

const GameDebugSessionScript := preload("res://addons/godot_ai_chat/scripts/tools/debug_tool/game_debug_session.gd")

var _suspended: bool = false


func _init() -> void:
	tool_name = "frame_step_game"
	tool_description = "Suspends the running game (freezes all processing) and advances it exactly one frame at a time, or resumes it. Useful for reproducing frame-order / timing bugs."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["suspend", "next_frame", "resume", "status"],
				"description": "suspend: freeze the game at SceneTree level (required before stepping). next_frame: advance exactly 1 frame (game must be suspended). resume: unfreeze and run normally. status: report state."
			}
		},
		"required": ["action"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")
	
	var action: String = p_args.get("action", "status")
	
	var plugin: EditorDebuggerPlugin = GameDebugSessionScript.get_instance()
	var session: EditorDebuggerSession = plugin.get_active_session() if plugin else null
	if session == null:
		return ToolResult.fail("Error: no active game debug session. Run the game first (e.g. via run_game).")
	
	match action:
		"suspend":
			session.send_message("scene:suspend_changed", [true])
			_suspended = true
			return ToolResult.ok("Game suspended. Now use action='next_frame' to step frame by frame.")
		"next_frame":
			if not _suspended:
				return ToolResult.fail("Error: game is not suspended. Call action='suspend' first.")
			session.send_message("scene:next_frame", [])
			return ToolResult.ok("Advanced exactly 1 frame.")
		"resume":
			session.send_message("scene:suspend_changed", [false])
			_suspended = false
			return ToolResult.ok("Game resumed.")
		"status":
			return ToolResult.ok("Game running: %s | suspended: %s" % [str(session.is_active()), str(_suspended)])
		_:
			return ToolResult.fail("Error: invalid action '%s'." % action)
