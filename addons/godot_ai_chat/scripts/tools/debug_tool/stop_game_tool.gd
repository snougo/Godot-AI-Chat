@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "stop_game"
	tool_description = "Stops the currently running/playing scene in the editor."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(_p_args: Dictionary) -> Dictionary:
	# 检查是否在编辑器中
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Error: This tool can only be used in the Godot editor."}
	
	# 执行停止场景
	EditorInterface.stop_playing_scene()
	return {"success": true, "data": "⏹️ Stopped the running scene."}
