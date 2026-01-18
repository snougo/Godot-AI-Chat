@tool
extends BaseSceneTool

func _init() -> void:
	tool_name = "set_node_property"
	tool_description = "Modifies a node property. REQUIRES 'node_path' from 'get_current_active_scene'."

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": { "type": "string", "description": "Path to the node." },
			"property_name": { "type": "string", "description": "Name of property (e.g. 'position', 'mesh:size'). Use ':' to access sub-resources." },
			"value": { "type": "string", "description": "Value. For complex types, use JSON string (e.g. '[1, 2]'). For resources: 'res://path' or 'new:ClassName'." }
		},
		"required": ["node_path", "property_name", "value"]
	}

func execute(args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Editor only."}
	
	var root = EditorInterface.get_edited_scene_root()
	if not root:
		return {"success": false, "data": "No active scene."}
	
	var path = args.get("node_path", "")
	var node = root if path == "." else root.get_node_or_null(path)
	if not node:
		return {"success": false, "data": "Node not found: %s" % path}
	
	var prop_name: String = args.get("property_name", "")
	var raw_value = args.get("value")
	
	# --- 1. 严格检查：属性是否存在 ---
	var top_level_prop = prop_name
	if ":" in prop_name:
		top_level_prop = prop_name.split(":")[0]
	
	if top_level_prop in PROPERTY_BLACKLIST:
		return {"success": false, "data": "Error: Modification of property '%s' is not allowed." % prop_name}
	
	if not (top_level_prop in node):
		var found := false
		for p in node.get_property_list():
			if p.name == top_level_prop:
				found = true
				break
		if not found:
			return {"success": false, "data": "Error: Property '%s' does not exist on node '%s' (%s)." % [top_level_prop, node.name, node.get_class()]}
	
	# --- 2. 类型转换与兼容性检查 ---
	var current_val = node.get_indexed(prop_name)
	var final_value = raw_value
	var target_type = TYPE_NIL
	
	if current_val != null:
		target_type = typeof(current_val)
		final_value = convert_to_type(raw_value, target_type)
		
		var final_type: int = typeof(final_value)
		if not is_type_compatible(target_type, final_type):
			return {
				"success": false, 
				"data": "Error: Type mismatch for property '%s'. Expected %s, but got %s (parsed from '%s')." % 
				[prop_name, get_type_name(target_type), get_type_name(final_type), str(raw_value)]
			}
	else:
		final_value = try_infer_type_from_string(raw_value)
		
		if final_value is String:
			if final_value.begins_with("res://"):
				if ResourceLoader.exists(final_value):
					final_value = ResourceLoader.load(final_value)
				else:
					return {"success": false, "data": "Error: Resource not found at '%s'." % final_value}
			else:
				var type_to_create = ""
				if final_value.begins_with("new:"):
					type_to_create = final_value.substr(4)
				elif ClassDB.class_exists(final_value):
					type_to_create = final_value
				
				if type_to_create != "":
					if ClassDB.class_exists(type_to_create):
						final_value = ClassDB.instantiate(type_to_create)
					elif final_value.begins_with("new:"):
						return {"success": false, "data": "Error: Class '%s' does not exist." % type_to_create}
	
	# --- 3. 执行设置 ---
	var undo_redo = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("AI Set Property")
	
	if ":" in prop_name:
		undo_redo.add_do_method(node, "set_indexed", prop_name, final_value)
		undo_redo.add_undo_method(node, "set_indexed", prop_name, current_val)
	else:
		undo_redo.add_do_property(node, prop_name, final_value)
		undo_redo.add_undo_property(node, prop_name, current_val)
	
	undo_redo.commit_action()
	
	# --- 4. 赋值后验证 ---
	var new_actual_val = node.get_indexed(prop_name)
	
	if not is_value_approx_equal(new_actual_val, final_value):
		return {
			"success": false, 
			"data": "Warning: Property assignment executed, but value did not stick. " +
			"Expected: %s, Actual: %s. The property might be read-only or constrained by a setter." % [str(final_value), str(new_actual_val)]
		}
	
	return {"success": true, "data": "Property '%s' successfully set to %s" % [prop_name, str(final_value)]}
