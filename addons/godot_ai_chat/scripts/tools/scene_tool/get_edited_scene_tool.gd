@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "get_edited_scene"
	tool_description = "Retrieves the hierarchy of the currently edited scene in the Godot Editor. Use `open_file` first to open target scene"
	security_level = SecurityLevel.NONE


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(_p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Editor only tool.")
	
	var root: Node = get_active_scene_root()
	if not root:
		return ToolResult.fail("No active scene in editor.")
	
	var tree_str: String = get_scene_tree_string(root)
	return ToolResult.ok("Current Scene: %s\n```\n%s\n```" % [root.name, tree_str])
