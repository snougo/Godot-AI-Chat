@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "scene_node_manipulation"
	tool_description = "Add or delete nodes in the currently active scene. Returns the updated scene tree structure after operation."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["add_node", "delete_node"],
				"description": "The action to perform."
			},
			"parent_path": {
				"type": "string",
				"description": "Path to the parent node for 'add_node'. Defaults to '.' (root)."
			},
			 "node_path": {
				"type": "string",
				"description": "Path to the node to delete for 'delete_node'."
			},
			"node_class": {
				"type": "string",
				"description": "Godot class name (e.g. 'Node3D') or 'res://' path for 'add_node'."
			},
			"node_name": {
				"type": "string",
				"description": "Name for the new node."
			},
			"properties": {
				"type": "object",
				"description": "Initial properties for the new node."
			}
		},
		"required": ["action"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Editor only tool."}
	
	var root = EditorInterface.get_edited_scene_root()
	if not root:
		return {"success": false, "data": "No active scene in editor."}
	
	var action = p_args.get("action", "")
	var result = {}
	
	match action:
		"add_node":
			result = _execute_add_node(root, p_args)
		"delete_node":
			result = _execute_delete_node(root, p_args)
		_:
			return {"success": false, "data": "Unknown action."}
	
	if result.get("success", false):
		# Return the updated tree structure
		var tree_info = get_scene_tree_string(root)
		result["data"] = result["data"] + "\n\nUpdated Scene Tree:\n```\n" + tree_info + "\n```"
	
	return result


func _execute_add_node(root: Node, p_args: Dictionary) -> Dictionary:
	var parent_path = p_args.get("parent_path", ".")
	# Compatible with old 'node_path' argument if parent_path not set
	if parent_path == "." and p_args.has("node_path") and p_args["action"] == "add_node":
		parent_path = p_args["node_path"]
	
	var parent = root if parent_path == "." else root.get_node_or_null(parent_path)
	if not parent: return {"success": false, "data": "Parent not found: %s" % parent_path}
	
	var type = p_args.get("node_class", "")
	if type.is_empty():
		return {"success": false, "data": "node_class required."}
	
	var new_node = _instantiate_node(type)
	if not new_node:
		return {"success": false, "data": "Invalid type: %s" % type}
	
	var name = p_args.get("node_name", "NewNode")
	new_node.name = name 
	
	var props = p_args.get("properties", {})
	if props is Dictionary:
		apply_properties(new_node, props)
	
	var ur = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Add Node %s" % name)
	ur.add_do_method(parent, "add_child", new_node)
	ur.add_do_property(new_node, "owner", root)
	ur.add_do_reference(new_node)
	ur.add_undo_method(parent, "remove_child", new_node)
	ur.commit_action()
	
	return {"success": true, "data": "Added node '%s' to '%s'." % [new_node.name, parent.name]}


func _execute_delete_node(root: Node, p_args: Dictionary) -> Dictionary:
	var node_path = p_args.get("node_path", "")
	if node_path == "." or node_path.is_empty():
		return {"success": false, "data": "Cannot delete root node or empty path."}
	
	var node = root.get_node_or_null(node_path)
	if not node:
		return {"success": false, "data": "Node not found: %s" % node_path}
	
	var parent = node.get_parent()
	var ur = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Delete Node %s" % node.name)
	ur.add_do_method(parent, "remove_child", node)
	ur.add_undo_method(parent, "add_child", node)
	ur.add_undo_property(node, "owner", root)
	ur.add_undo_reference(node)
	ur.commit_action()
	
	return {"success": true, "data": "Deleted node: %s" % node.name}


func _instantiate_node(type_str: String) -> Node:
	if type_str.begins_with("res://"):
		if ResourceLoader.exists(type_str):
			var res = load(type_str)
			if res is PackedScene:
				return res.instantiate()
	elif ClassDB.class_exists(type_str):
		return ClassDB.instantiate(type_str)
	return null
