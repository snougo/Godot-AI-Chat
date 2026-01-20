@tool
extends BaseSceneTool

func _init() -> void:
	tool_name = "get_current_active_scene"
	tool_description = "Retrieves the scene tree. EXECUTE FIRST to get 'node_path' for add/get/set node tools."

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}

func execute(_args: Dictionary) -> Dictionary:
	var edited_root := EditorInterface.get_edited_scene_root()
	if edited_root:
		var file_path: String = edited_root.scene_file_path
		var file_name: String = file_path.get_file()
		
		if file_name.is_empty():
			file_name = "%s (Unsaved)" % edited_root.name
		
		var structure: String = _get_scene_tree_string(edited_root)
		var display_text: String = "Current Scene: **%s**\n\n```scene_tree\n%s\n```" % [file_name, structure]
		
		return {
			"success": true, 
			"data": display_text
		}
	
	return {"success": false, "data": "No active Scene found in Editor Tab."}

func _get_scene_tree_string(root: Node) -> String:
	var lines: PackedStringArray = []
	_traverse_node(root, root, 0, lines)
	return "\n".join(lines)

func _traverse_node(node: Node, root: Node, depth: int, lines: PackedStringArray) -> void:
	if node != root and node.owner != root:
		return
	
	var indent: String = "  ".repeat(depth)
	var type: String = node.get_class()
	var extra_info: String = ""
	
	if node != root and not node.scene_file_path.is_empty():
		extra_info = " [Instance: %s]" % node.scene_file_path
	
	lines.append("%s- %s (%s)%s" % [indent, node.name, type, extra_info])
	
	for child in node.get_children():
		_traverse_node(child, root, depth + 1, lines)
