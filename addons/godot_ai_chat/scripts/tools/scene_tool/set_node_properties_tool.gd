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
				"description": "Target node path (e.g., 'RootNode/ChildNode'). Use absolute paths from scene tree root."
			},
			"property_name": {
				"type": "string",
				"description": "Property to set (e.g., 'position'). Required."
			},
			"value": {
				"type": "string",
				"description": "Value to set. Supports types:\n- Vec2/3: '[x, y]'\n- Color: '[r, g, b, a]'\n- Resource: 'res://path' or 'new:ClassName'"
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
		# 提供当前场景树结构和路径建议
		var scene_tree: String = get_scene_tree_string(root)
		var suggestions: Array[String] = find_similar_paths(root, node_path)
		var suggestion_text: String = ""
		
		if not suggestions.is_empty():
			suggestion_text = "\n\nDid you mean:\n  - " + "\n  - ".join(suggestions)
		
		return {
			"success": false, 
			"data": "Node not found: %s\n\nCurrent Scene Tree:\n%s%s" % [node_path, scene_tree, suggestion_text]
		}
	
	var prop: String = p_args.get("property_name", "")
	if prop.is_empty():
		return {"success": false, "data": "property_name required."}
	
	# 检查属性是否在黑名单中
	var base_prop: String = prop.split(":")[0]
	if base_prop in PROPERTY_BLACKLIST:
		return {
			"success": false, 
			"data": "Property '%s' is in the blacklist and cannot be modified. Blacklisted properties: %s" % [base_prop, PROPERTY_BLACKLIST]
		}
	
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
	
	# 使用带验证的类型转换
	var final_val: Variant
	if target_type != TYPE_NIL:
		var conversion_result = convert_to_type_with_validation(raw_val, target_type)
		if not conversion_result.success:
			return {
				"success": false, 
				"data": "Type conversion failed for property '%s': %s" % [prop, conversion_result.error]
			}
		final_val = conversion_result.value
	else:
		# 无法确定类型时，尝试推断但不允许失败静默
		final_val = try_infer_type_from_string(raw_val)
		# 如果推断结果与原始值相同（字符串），但原始值不是字符串类型，可能是解析失败
		if final_val is String and not raw_val is String:
			return {
				"success": false,
				"data": "Could not infer type for value '%s'. Please provide value in correct format." % str(raw_val)
			}
	
	# 特殊处理 null 值
	if target_type == TYPE_OBJECT and final_val is String:
		if final_val.to_lower() == "null":
			final_val = null
		else:
			return {"success": false, "data": "Failed to load resource: '%s'. File may not exist or is invalid." % raw_val}
	
	if ":" in prop:
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
	
	# 返回完整节点属性快照
	var node_props := get_all_node_properties(node)
	
	return {"success": true, "data": {
		"node_path": node_path,
		"property_name": prop,
		"old_value": current,
		"new_value": final_val,
		"node_properties_snapshot": node_props
	}}
