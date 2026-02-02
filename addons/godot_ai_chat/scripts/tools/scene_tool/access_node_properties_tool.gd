@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "access_node_properties"
	tool_description = "Checks or Sets node properties within the active Godot scene."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["check_node_property", "set_node_property"],
				"description": "Action to perform. Using `check_node_property` before `set_node_property`."
			},
			"node_path": {
				"type": "string",
				"description": "Target node path (use '.' for root). Required for check/set property."
			},
			"property_name": {
				"type": "string",
				"description": "Property to set (e.g. 'position', 'mesh:size'). Required for 'set_node_property'."
			},
			"value": {
				"type": "string",
				"description": "Value to set. Supports types:\n- Vec2/3: '[x, y]', '[x, y, z]'\n- Color: '[r, g, b, a]'\n- Resource: 'res://path' or 'new:ClassName'"
			}
		},
		"required": ["action"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")
	
	if action == "check_node_property":
		return _execute_check_node_property(p_args)
	
	elif action == "set_node_property":
		return _execute_set_node_property(p_args)
	
	return {"success": false, "data": "Unknown action: %s" % action}


func _execute_check_node_property(p_args: Dictionary) -> Dictionary:
	var root: Node = get_active_scene_root()
	if not root:
		return {"success": false, "data": "No active scene."}
	
	var node_path: String = p_args.get("node_path", ".")
	var target: Node = get_node_from_root(root, node_path)
	if not target:
		return {"success": false, "data": "Node not found: %s" % node_path}
	
	# Collect info
	var info: Dictionary = {
		"name": target.name,
		"class": target.get_class(),
		"children": [],
		"properties": {}
	}
	for c in target.get_children():
		info.children.append("%s (%s)" % [c.name, c.get_class()])
	
	for p in target.get_property_list():
		if p.usage & PROPERTY_USAGE_EDITOR:
			info.properties[p.name] = str(target.get(p.name))
	
	return {"success": true, "data": info}


func _execute_set_node_property(p_args: Dictionary) -> Dictionary:
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
	
	# Try to find property type definition from metadata
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
	
	# Fallback
	if not found_def and current != null:
		target_type = typeof(current)
	
	var final_val: Variant = raw_val
	if target_type != TYPE_NIL:
		final_val = convert_to_type(raw_val, target_type)
	else:
		final_val = try_infer_type_from_string(raw_val)
	
	# 强校验对象类型转换
	if target_type == TYPE_OBJECT and final_val is String:
		if final_val.to_lower() == "null":
			final_val = null
		else:
			return {"success": false, "data": "Failed to load resource: '%s'. File may not exist or is invalid." % raw_val}
	
	# 校验嵌套属性的基础对象
	if ":" in prop:
		var base_prop: String = prop.split(":")[0]
		var sub_prop: String = prop.split(":")[1]
		var base_obj: Variant = node.get(base_prop)
		if base_obj == null:
			return {"success": false, "data": "Cannot set property '%s': Base object '%s' is null." % [prop, base_prop]}
		
		# 额外验证：检查子属性是否存在
		if base_obj is Object and not base_obj.has(sub_prop):
			return {"success": false, "data": "Property '%s' not found on %s." % [sub_prop, base_prop]}
	
	# 关键修复：使用延迟执行避免与检查器刷新冲突
	var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Set Property %s" % prop)
	
	# 执行设置
	#var ur: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Set Property %s" % prop)
	if ":" in prop:
		#ur.add_do_method(node, "set_indexed", prop, final_val)
		#ur.add_undo_method(node, "set_indexed", prop, current)
		# 对于嵌套属性，使用延迟调用避免竞态条件
		ur.add_do_method(node, "call_deferred", "set_indexed", prop, final_val)
		ur.add_undo_method(node, "call_deferred", "set_indexed", prop, current)
	else:
		ur.add_do_property(node, prop, final_val)
		ur.add_undo_property(node, prop, current)
	ur.commit_action()
	
	return {"success": true, "data": "Property '%s' set to %s" % [prop, str(final_val)]}
