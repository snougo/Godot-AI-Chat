@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "get_edited_scene_tree"
	tool_description = "Retrieves the hierarchy of the currently edited scene in the Godot Editor."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(_p_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Editor only tool."}
	
	var root: Node = get_active_scene_root()
	if not root:
		return {"success": false, "data": "No active scene in editor."}
	
	var tree_str: String = get_scene_tree_string(root)
	return {"success": true, "data": "Current Scene: %s\n```\n%s\n```" % [root.name, tree_str]}
