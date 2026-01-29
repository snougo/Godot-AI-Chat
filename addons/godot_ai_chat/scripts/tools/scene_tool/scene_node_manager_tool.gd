@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "scene_node_manager"
	tool_description = "Add, delete, or move nodes in the currently active scene. Focuses on scene tree structure management."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["get_scene_tree", "add_node", "delete_node", "move_node"],
				"description": "The action to perform. Using `get_scene_tree` before add/delete/move node."
			},
			"node_path": {
				"type": "string",
				"description": "Target node path. Required for 'delete_node' and 'move_node'."
			},
			"parent_path": {
				"type": "string",
				"description": "Target parent path. Required for 'move_node'. Optional for 'add_node' (defaults to root)."
			},
			"node_class": {
				"type": "string",
				"description": "Class name (e.g., 'Node3D') or 'res://' path. Required for 'add_node'."
			},
			"node_name": {
				"type": "string",
				"description": "Name for the new node. Optional for 'add_node'."
			}
		},
		"required": ["action"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Editor only tool."}
	
	var root: Node = get_active_scene_root()
	if not root:
		return {"success": false, "data": "No active scene in editor."}
	
	var action: String = p_args.get("action", "")
	var result: Dictionary = {}
	
	match action:
		"get_scene_tree":  # 新增分支
			return _execute_get_scene_tree(root)
		"add_node":
			result = _execute_add_node(root, p_args)
		"delete_node":
			result = _execute_delete_node(root, p_args)
		"move_node":
			result = _execute_move_node(root, p_args)
		_:
			return {"success": false, "data": "Unknown action."}
	
	if result.get("success", false):
		# Return the updated tree structure
		var tree_info: String = get_scene_tree_string(root)
		result["data"] = result["data"] + "\n\nUpdated Scene Tree:\n```\n" + tree_info + "\n```"
	
	return result


func _execute_get_scene_tree(root: Node) -> Dictionary:
	var tree_str: String = get_scene_tree_string(root)
	return {"success": true, "data": "Current Scene: %s\n```\n%s\n```" % [root.name, tree_str]}


func _execute_add_node(root: Node, p_args: Dictionary) -> Dictionary:
	var parent_path: String = p_args.get("parent_path", ".")
	var parent: Node = get_node_from_root(root, parent_path)
	if not parent:
		return {"success": false, "data": "Parent not found: %s" % parent_path}
	
	var type: String = p_args.get("node_class", "")
	if type.is_empty():
		return {"success": false, "data": "node_class required."}
	
	var new_node: Node = instantiate_node_from_type(type)
	if not new_node:
		return {"success": false, "data": "Invalid type: %s" % type}
	
	var name: String = p_args.get("node_name", "NewNode")
	new_node.name = name 
	
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Add Node %s" % name)
	ur.add_do_method(parent, "add_child", new_node)
	ur.add_do_property(new_node, "owner", root)
	ur.add_do_reference(new_node)
	ur.add_undo_method(parent, "remove_child", new_node)
	ur.commit_action()
	
	return {"success": true, "data": "Added node '%s' to '%s'." % [new_node.name, parent.name]}


func _execute_delete_node(root: Node, p_args: Dictionary) -> Dictionary:
	var node_path: String = p_args.get("node_path", "")
	if node_path == "." or node_path.is_empty():
		return {"success": false, "data": "Cannot delete root node or empty path."}
	
	var node: Node = get_node_from_root(root, node_path)
	if not node:
		return {"success": false, "data": "Node not found: %s" % node_path}
	
	var parent: Node = node.get_parent()
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Delete Node %s" % node.name)
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node)
	ur.add_undo_property(node, "owner", root)
	ur.add_undo_reference(node)
	ur.commit_action()
	
	return {"success": true, "data": "Deleted node: %s" % node.name}


func _execute_move_node(root: Node, p_args: Dictionary) -> Dictionary:
	var node_path: String = p_args.get("node_path", "")
	var target_parent_path: String = p_args.get("parent_path", "")
	
	if node_path.is_empty() or target_parent_path.is_empty():
		return {"success": false, "data": "Both node_path and parent_path are required for move_node."}
		
	var node: Node = get_node_from_root(root, node_path)
	if not node:
		return {"success": false, "data": "Node not found: %s" % node_path}
	
	if node == root:
		return {"success": false, "data": "Cannot move root node."}
	
	var new_parent: Node = get_node_from_root(root, target_parent_path)
	if not new_parent:
		return {"success": false, "data": "Target parent not found: %s" % target_parent_path}
	
	if node.get_parent() == new_parent:
		return {"success": false, "data": "Node is already a child of the target parent."}
	
	# Check for circular dependency
	var temp: Node = new_parent
	while temp:
		if temp == node:
			return {"success": false, "data": "Cannot move node into its own child."}
		temp = temp.get_parent()

	var old_parent: Node = node.get_parent()
	
	# Use standard reparent logic via UndoRedo
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Move Node %s" % node.name)
	
	# Do: Remove from old -> Add to new -> Set owner
	ur.add_do_method(old_parent, "remove_child", node)
	ur.add_do_method(new_parent, "add_child", node)
	ur.add_do_property(node, "owner", root) # Re-assign owner just in case
	
	# Undo: Remove from new -> Add to old -> Set owner
	ur.add_undo_method(new_parent, "remove_child", node)
	ur.add_undo_method(old_parent, "add_child", node)
	ur.add_undo_property(node, "owner", root)
	
	ur.commit_action()
	
	return {"success": true, "data": "Moved node '%s' to '%s'." % [node.name, new_parent.name]}
