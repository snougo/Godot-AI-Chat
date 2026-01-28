@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "scene_inspector"
	tool_description = "Inspect and modify node properties in the current active scene of Scene Edito. Get scene tree structure, check node property, or set property."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["get_scene_tree", "check_node_property", "set_node_property"],
				"description": "The action to perform."
			},
			"node_path": {
				"type": "string",
				"description": "Path to the node relative to scene root (use '.' for root). Required for 'check_node_property' and 'set_node_property'."
			},
			"property_name": {
				"type": "string",
				"description": "Property name for 'set_node_property'. Supports both direct properties (e.g. 'position', 'rotation', 'modulate') and nested properties using ':' separator (e.g. 'mesh:size', 'material:albedo_color', 'texture:resource_path')."
			},
			"value": {
				"type": "string",
				"description": "Value for 'set_node_property'. Format depends on target type:\n
				- Vectors: '[100, 200]' (Vector2), '[1, 2, 3]' (Vector3)\n
				- Color: '[1, 0.5, 0]' or '[1, 0.5, 0, 0.8]'\n
				- Sub-Resource: 'res://icon.svg' (sub-resource path), 'new:GradientTexture2D' (sub-resource type)."
			}
		},
		"required": ["action"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")
	
	if action == "get_scene_tree":
		var root = EditorInterface.get_edited_scene_root()
		if not root:
			return {"success": false, "data": "No active scene."}
		var tree_str = get_scene_tree_string(root)
		return {"success": true, "data": "Current Scene: %s\n```\n%s\n```" % [root.name, tree_str]}
	
	if action == "check_node_property":
		return _execute_check_node_property(p_args)
	
	if action == "set_node_property":
		if not Engine.is_editor_hint():
			return {"success": false, "data": "Editor only tool."}
		var root = EditorInterface.get_edited_scene_root()
		if not root:
			return {"success": false, "data": "No active scene in editor."}
		return _execute_set_node_property(root, p_args)
	
	return {"success": false, "data": "Unknown action: %s" % action}


func _execute_check_node_property(p_args: Dictionary) -> Dictionary:
	var node_path = p_args.get("node_path", ".")
	
	var root = EditorInterface.get_edited_scene_root()
	if not root:
		return {"success": false, "data": "No active scene."}
	
	var target = root if node_path == "." else root.get_node_or_null(node_path)
	if not target:
		return {"success": false, "data": "Node not found: %s" % node_path}
	
	# Collect info
	var info = {
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


func _execute_set_node_property(root: Node, p_args: Dictionary) -> Dictionary:
	var node_path = p_args.get("node_path", ".")
	var node = root if node_path == "." else root.get_node_or_null(node_path)
	if not node:
		return {"success": false, "data": "Node not found: %s" % node_path}
	
	var prop = p_args.get("property_name", "")
	if prop.is_empty():
		return {"success": false, "data": "property_name required."}
	
	var raw_val = p_args.get("value")
	
	if not is_prop_valid(node, prop):
		return {"success": false, "data": "Property '%s' not found or invalid on %s." % [prop, node.name]}
	
	var current = node.get_indexed(prop)
	var target_type: int = TYPE_NIL
	
	# Try to find property type definition from metadata
	var prop_list = node.get_property_list()
	var found_def = false
	
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
	
	var final_val = raw_val
	if target_type != TYPE_NIL:
		final_val = convert_to_type(raw_val, target_type)
	else:
		final_val = try_infer_type_from_string(raw_val)
	
	# --- 修复点 1: 强校验对象类型转换 ---
	# 如果目标是对象/资源，但转换结果仍是字符串，说明资源加载失败（路径错误或文件不存在）
	if target_type == TYPE_OBJECT and final_val is String:
		if final_val.to_lower() == "null":
			final_val = null
		else:
			return {"success": false, "data": "Failed to load resource: '%s'. File may not exist or is invalid." % raw_val}
	
	# --- 修复点 2: 校验嵌套属性的基础对象 ---
	# 例如设置 "mesh:size"，必须确保 "mesh" 不为 null
	if ":" in prop:
		var base_prop = prop.split(":")[0]
		var base_obj = node.get(base_prop)
		if base_obj == null:
			return {"success": false, "data": "Cannot set property '%s': Base object '%s' is null." % [prop, base_prop]}
	
	# 执行设置
	var ur = EditorInterface.get_editor_undo_redo()
	ur.create_action("AI Set Property %s" % prop)
	if ":" in prop:
		ur.add_do_method(node, "set_indexed", prop, final_val)
		ur.add_undo_method(node, "set_indexed", prop, current)
	else:
		ur.add_do_property(node, prop, final_val)
		ur.add_undo_property(node, prop, current)
	ur.commit_action()
	
	# --- 修复点 3: 结果验证 (可选但推荐) ---
	# 立即读取属性检查是否应用成功
	var new_val = node.get_indexed(prop)
	# 注意：资源比较可能涉及引用问题，但在立即设置后，通常 new_val 应该等于 final_val
	if target_type == TYPE_OBJECT and final_val != null and new_val != final_val:
		return {"success": false, "data": "Set operation appeared to fail. Property '%s' value did not change to expected resource." % prop}
	
	return {"success": true, "data": "Property '%s' set to %s" % [prop, str(final_val)]}
