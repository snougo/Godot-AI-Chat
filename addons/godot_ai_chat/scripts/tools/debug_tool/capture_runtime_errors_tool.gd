@tool
extends AiTool


func _init() -> void:
	tool_name = "capture_runtime_errors"
	tool_description = "Retrieves runtime errors captured from the last game session launched from the editor. Call this to get crash info, GDScript errors, and push_error messages that occurred during gameplay."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"clear_after_read": {
				"type": "boolean",
				"description": "If true, clears the captured errors after reading. Default: true."
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Error: This tool can only be used in the Godot editor."}
	
	var DebuggerScript: GDScript = load(
		"res://addons/godot_ai_chat/scripts/tools/debug_tool/runtime_error_debugger.gd"
	)
	if not DebuggerScript:
		return {"success": false, "data": "Error: Failed to load runtime_error_debugger.gd"}
	
	var clear_after_read: bool = p_args.get("clear_after_read", true)
	var errors: Array[Dictionary] = DebuggerScript.get("captured_errors").duplicate()
	
	if errors.is_empty():
		return {
			"success": true,
			"data": "No runtime errors were captured from the last game session. The game may have run without errors, or no game session has been started yet."
		}
	
	var output: String = "Captured %d runtime error(s) from the last game session:\n\n" % errors.size()
	for i in errors.size():
		var err: Dictionary = errors[i]
		output += "=== Error #%d ===\n" % (i + 1)
		output += "  File:     %s:%d\n" % [err.get("file", "Unknown"), err.get("line", 0)]
		output += "  Function: %s\n" % err.get("function", "Unknown")
		output += "  Message:  %s\n" % err.get("code", "")
		
		match err.get("error_type", -1):
			Logger.ERROR_TYPE_ERROR:
				output += "  Type:     ERROR\n"
			Logger.ERROR_TYPE_WARNING:
				output += "  Type:     WARNING\n"
			Logger.ERROR_TYPE_SCRIPT:
				output += "  Type:     SCRIPT_ERROR\n"
			Logger.ERROR_TYPE_SHADER:
				output += "  Type:     SHADER_ERROR\n"
			_:
				output += "  Type:     %d\n" % err.get("error_type", -1)
		
		var backtraces: String = err.get("backtraces", "")
		if not backtraces.is_empty():
			output += "  Backtrace:\n%s\n" % backtraces
		output += "\n"
	
	if clear_after_read:
		DebuggerScript.set("captured_errors", [])
		output += "\n(Errors cleared after read.)"
	
	return {"success": true, "data": output}
