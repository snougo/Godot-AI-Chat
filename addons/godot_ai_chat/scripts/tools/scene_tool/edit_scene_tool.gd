@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "edit_scene"
	tool_description = "Adds, deletes, moves node to modify the SceneTree hierarchy."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["add_node", "delete_node", "move_node"],
				"description": "Operation to perform. Use 'get_edited_scene' first to view current scene."
			},
			"node_path": {
				"type": "string",
				"description": "Target node path."
			},
			"parent_path": {
				"type": "string",
				"description": "Target parent path."
			},
			"node_class": {
				"type": "string",
				"description": "Class name (e.g. 'Sprite2D', 'Node3D') or 'res://path/to/scene.tscn'. Required for: add_node."
			},
			"node_name": {
				"type": "string",
				"description": "Name for the new node. Optional (auto-generated if empty)."
			}
		},
		"required": ["action"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")
	
	var root: Node = get_active_scene_root()
	if not root:
		return ToolResult.fail("Error: no active scene in editor.")
	
	var action: String = p_args.get("action", "")
	
	var result: ToolResult
	match action:
		"add_node":
			result = _execute_add_node(root, p_args)
		"delete_node":
			result = _execute_delete_node(root, p_args)
		"move_node":
			result = _execute_move_node(root, p_args)
		_:
			return ToolResult.fail("Error: unknown action.")
	
	if result.is_ok():
		# Return the updated tree structure
		var tree_info: String = get_scene_tree_string(root)
		return ToolResult.ok(result.get_data() + "\n\nUpdated Scene Tree:\n```\n" + tree_info + "\n```")
	else:
		return result


func _execute_add_node(root: Node, p_args: Dictionary) -> ToolResult:
	var parent_path: String = p_args.get("parent_path", ".")
	var parent: Node = get_node_from_root(root, parent_path)
	if not parent:
		var hint = get_node_path_error_hint(root, parent_path)
		return ToolResult.fail("Error: parent not found.\n" + hint)
	
	var type: String = p_args.get("node_class", "")
	if type.is_empty():
		return ToolResult.fail("Error: node_class required.")
	
	var new_node: Node = instantiate_node_from_type(type)
	if not new_node:
		return ToolResult.fail("Error: invalid type: %s" % type)
	
	var name: String = p_args.get("node_name", "NewNode")
	new_node.name = name
	
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Add Node %s" % name)
	ur.add_do_method(parent, "add_child", new_node)
	ur.add_do_property(new_node, "owner", root)
	ur.add_do_reference(new_node)
	ur.add_undo_method(parent, "remove_child", new_node)
	ur.commit_action()
	
	return ToolResult.ok("Added node '%s' to '%s'." % [new_node.name, parent.name])


func _execute_delete_node(root: Node, p_args: Dictionary) -> ToolResult:
	var node_path: String = p_args.get("node_path", "")
	if node_path == "." or node_path.is_empty():
		return ToolResult.fail("Error: can not delete root node or empty path.")
	
	var node: Node = get_node_from_root(root, node_path)
	if not node:
		var hint = get_node_path_error_hint(root, node_path)
		return ToolResult.fail("Node not found.\n" + hint)
	
	var parent: Node = node.get_parent()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Delete Node %s" % node.name)
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node)
	ur.add_undo_property(node, "owner", root)
	ur.add_undo_reference(node)
	ur.commit_action()
	
	return ToolResult.ok("Deleted node: %s" % node.name)


func _execute_move_node(root: Node, p_args: Dictionary) -> ToolResult:
	var node_path: String = p_args.get("node_path", "")
	var target_parent_path: String = p_args.get("parent_path", "")
	
	if node_path.is_empty() or target_parent_path.is_empty():
		return ToolResult.fail("Erroe: both node_path and parent_path are required for move_node.")
	
	var node: Node = get_node_from_root(root, node_path)
	if not node:
		var hint = get_node_path_error_hint(root, node_path)
		return ToolResult.fail("Error: node not found.\n" + hint)
	
	if node == root:
		return ToolResult.fail("Error: can not move root node.")
	
	var new_parent: Node = get_node_from_root(root, target_parent_path)
	if not new_parent:
		var hint = get_node_path_error_hint(root, target_parent_path)
		return ToolResult.fail("Error: target parent not found.\n" + hint)
	
	if node.get_parent() == new_parent:
		return ToolResult.fail("Error: node is already a child of the target parent.")
	
	# Check for circular dependency
	var temp: Node = new_parent
	while temp:
		if temp == node:
			return ToolResult.fail("Error: can not move node into its own child.")
		temp = temp.get_parent()
	
	var old_parent: Node = node.get_parent()
	
	# Use standard reparent logic via UndoRedo
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Move Node %s" % node.name)
	
	# Do: Remove from old -> Add to new -> Set owner
	ur.add_do_method(old_parent, "remove_child", node)
	ur.add_do_method(new_parent, "add_child", node)
	ur.add_do_property(node, "owner", root)
	
	# Undo: Remove from new -> Add to old -> Set owner
	ur.add_undo_method(new_parent, "remove_child", node)
	ur.add_undo_method(old_parent, "add_child", node)
	ur.add_undo_property(node, "owner", root)
	
	ur.commit_action()
	
	return ToolResult.ok("Moved node '%s' to '%s'." % [node.name, new_parent.name])
