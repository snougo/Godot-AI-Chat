@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "set_node_properties"
	tool_description = "Sets a property value on a node in the current edited scene. Supports Undo/Redo."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Target node path (use '.' for root). Required."
			},
			"property_name": {
				"type": "string",
				"description": "Property to set (e.g. 'position', 'mesh:size'). Required."
			},
			"value": {
				"type": "string",
				"description": "Value to set. Supports types:\n- Vec2/3: '[x, y]', '[x, y, z]'\n- Color: '[r, g, b, a]'\n- Resource: 'res://path' or 'new:ClassName'"
			}
		},
		"required": ["node_path", "property_name", "value"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var root: Node = get_active_scene_root()
	if not root:
		return {"success": false, "data": "No active scene in editor."}
	
	var node_path: String = p_args.get("node_path", ".")
	var node: Node = get_node_from_root(root, node_path)
	if not node:
		return {"success": false, "data": "Node not found: %s" % node_path}
	
	var prop: String = p_args.get("property_name", "")
	if prop.is_empty():
		return {"success": false, "data": "property_name required."}
	
	var raw_val: Variant = p_args.get("value")
	
	if not is_prop_valid(node, prop):
		return {"success": false, "data": "Property '%s' not found or invalid on %s." % [prop, node.name]}
	
	var current: Variant = node.get_indexed(prop)
	var target_type: int = TYPE_NIL
	var prop_list: Array = node.get_property_list()
	var found_def: bool = false
	
	if ":" in prop:
		if current != null:
			target_type = typeof(current)
			found_def = true
	else:
		for p in prop_list:
			if p.name == prop:
				target_type = p.type
				found_def = true
				break
	
	if not found_def and current != null:
		target_type = typeof(current)
	
	var final_val: Variant = raw_val
	if target_type != TYPE_NIL:
		final_val = convert_to_type(raw_val, target_type)
	else:
		final_val = try_infer_type_from_string(raw_val)
	
	if target_type == TYPE_OBJECT and final_val is String:
		if final_val.to_lower() == "null":
			final_val = null
		else:
			return {"success": false, "data": "Failed to load resource: '%s'. File may not exist or is invalid." % raw_val}
	
	if ":" in prop:
		var base_prop: String = prop.split(":")[0]
		var sub_prop: String = prop.split(":")[1]
		var base_obj: Variant = node.get(base_prop)
		if base_obj == null:
			return {"success": false, "data": "Cannot set property '%s': Base object '%s' is null." % [prop, base_prop]}
		if base_obj is Object and not base_obj.has(sub_prop):
			return {"success": false, "data": "Property '%s' not found on %s." % [sub_prop, base_prop]}
	
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Set Property %s" % prop)
	
	if ":" in prop:
		ur.add_do_method(node, "call_deferred", "set_indexed", prop, final_val)
		ur.add_undo_method(node, "call_deferred", "set_indexed", prop, current)
	else:
		ur.add_do_property(node, prop, final_val)
		ur.add_undo_property(node, prop, current)
	
	ur.commit_action()
	
	return {"success": true, "data": "Property '%s' set to %s" % [prop, str(final_val)]}
