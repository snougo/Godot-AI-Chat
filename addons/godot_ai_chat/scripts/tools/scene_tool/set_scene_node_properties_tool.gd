@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "set_scene_node_properties"
	tool_description = "Sets a property on a node with type coercion and UndoRedo support."
	security_level = SecurityLevel.PATH_VALIDATED


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Target node path."
			},
			"property_name": {
				"type": "string",
				"description": "Property name. Supports ':' for nested resource properties."
			},
			"value": {
				"type": "string",
				"description": "Value to set. Auto-converts to the target type."
			}
		},
		"required": ["node_path", "property_name", "value"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var root: Node = get_active_scene_root()
	if not root:
		return ToolResult.fail("No active scene in editor.")
	
	var node_path: String = p_args.get("node_path", ".")
	var node: Node = get_node_from_root(root, node_path)
	
	if not node:
		var hint = get_node_path_error_hint(root, node_path)
		return ToolResult.fail(hint)
	
	var prop: String = p_args.get("property_name", "")
	if prop.is_empty():
		return ToolResult.fail("property_name required.")
	
	# 检查属性是否在黑名单中
	var base_prop: String = prop.split(":")[0]
	if base_prop in PROPERTY_BLACKLIST:
		return ToolResult.fail("Property '%s' is in the blacklist and cannot be modified. Blacklisted properties: %s" % [base_prop, PROPERTY_BLACKLIST])
	
	var raw_val: Variant = p_args.get("value")
	
	if not is_prop_valid(node, prop):
		return ToolResult.fail("Property '%s' not found or invalid on %s." % [prop, node.name])
	
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
	
	# 使用带验证的类型转换
	var final_val: Variant
	if target_type != TYPE_NIL:
		var conversion_result = convert_to_type_with_validation(raw_val, target_type)
		if not conversion_result.success:
			return ToolResult.fail("Type conversion failed for property '%s': %s" % [prop, conversion_result.error])
		final_val = conversion_result.value
	else:
		final_val = try_infer_type_from_string(raw_val)
		if final_val is String and not raw_val is String:
			return ToolResult.fail("Could not infer type for value '%s'. Please provide value in correct format." % str(raw_val))
	
	if target_type == TYPE_OBJECT and final_val is String:
		if final_val.to_lower() == "null":
			final_val = null
		else:
			return ToolResult.fail("Failed to load resource: '%s'. File may not exist or is invalid." % raw_val)
	
	if ":" in prop:
		var sub_prop: String = prop.split(":")[1]
		var base_obj: Variant = node.get(base_prop)
		if base_obj == null:
			return ToolResult.fail("Cannot set property '%s': Base object '%s' is null." % [prop, base_prop])
		if base_obj is Object and not _object_has_property(base_obj, sub_prop):
			return ToolResult.fail("Property '%s' not found on %s." % [sub_prop, base_prop])
	
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Set Property %s" % prop)
	
	if ":" in prop:
		ur.add_do_method(node, "call_deferred", "set_indexed", prop, final_val)
		ur.add_undo_method(node, "call_deferred", "set_indexed", prop, current)
	else:
		ur.add_do_property(node, prop, final_val)
		ur.add_undo_property(node, prop, current)
	
	ur.commit_action()
	
	var node_props := get_all_node_properties(node)
	
	var result_dict := {
		"node_path": node_path,
		"property_name": prop,
		"old_value": current,
		"new_value": final_val,
		"node_properties_snapshot": node_props
	}
	
	return ToolResult.ok(JSON.stringify(result_dict, "\t"))


func _object_has_property(obj: Object, prop_name: String) -> bool:
	if obj == null:
		return false
	for p in obj.get_property_list():
		if p.name == prop_name:
			return true
	return false
