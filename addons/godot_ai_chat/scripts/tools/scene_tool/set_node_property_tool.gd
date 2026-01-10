@tool
extends BaseSceneTool

func _init() -> void:
	tool_name = "set_current_scene_node_property"
	tool_description = "Modifies a property of a node in the currently active scene with strict validation. Examples: 'position', 'rotation_degrees', 'text', 'modulate', 'mesh:size' (nested properties), or resource paths."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": { "type": "string", "description": "Path to the node." },
			"property_name": { "type": "string", "description": "Name of property (e.g. 'position', 'mesh:size')." },
			"value": { "type": "string", "description": "Value. For complex types, use JSON string (e.g. '[1, 2]'). For resources: 'res://path'." }
		},
		"required": ["node_path", "property_name", "value"]
	}


func execute(args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	if not Engine.is_editor_hint(): return {"success": false, "data": "Editor only."}
	
	var root = EditorInterface.get_edited_scene_root()
	if not root: return {"success": false, "data": "No active scene."}
	
	var path = args.get("node_path", "")
	var node = root if path == "." else root.get_node_or_null(path)
	if not node: return {"success": false, "data": "Node not found: %s" % path}
	
	var prop_name: String = args.get("property_name", "")
	var raw_value = args.get("value")
	
	# --- 1. 严格检查：属性是否存在 ---
	var top_level_prop = prop_name.split(":")[0]
	
	if top_level_prop in PROPERTY_BLACKLIST:
		return {"success": false, "data": "Error: Modification of property '%s' is not allowed." % prop_name}
	
	if not (top_level_prop in node):
		var found = false
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
		final_value = _convert_to_type(raw_value, target_type)
		
		var final_type = typeof(final_value)
		if not _is_type_compatible(target_type, final_type):
			return {
				"success": false, 
				"data": "Error: Type mismatch for property '%s'. Expected %s, but got %s (parsed from '%s')." % 
				[prop_name, _get_type_name(target_type), _get_type_name(final_type), str(raw_value)]
			}
	else:
		final_value = _try_infer_type_from_string(raw_value)
		
		if raw_value is String:
			if raw_value.begins_with("new:"):
				var type_name = raw_value.substr(4)
				if ClassDB.class_exists(type_name):
					final_value = ClassDB.instantiate(type_name)
				else:
					return {"success": false, "data": "Error: Class '%s' does not exist." % type_name}
			elif raw_value.begins_with("res://"):
				if ResourceLoader.exists(raw_value):
					final_value = ResourceLoader.load(raw_value)
				else:
					return {"success": false, "data": "Error: Resource not found at '%s'." % raw_value}
	
	# --- 3. 执行设置 (核心修复) ---
	var undo_redo = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("AI Set Property")
	
	# [修复点] 如果属性名包含冒号，说明是嵌套属性，必须使用 set_indexed 方法
	if ":" in prop_name:
		undo_redo.add_do_method(node, "set_indexed", prop_name, final_value)
		undo_redo.add_undo_method(node, "set_indexed", prop_name, current_val)
	else:
		undo_redo.add_do_property(node, prop_name, final_value)
		undo_redo.add_undo_property(node, prop_name, current_val)
		
	undo_redo.commit_action()
	
	# --- 4. 赋值后验证 ---
	var new_actual_val = node.get_indexed(prop_name)
	
	if not _is_value_approx_equal(new_actual_val, final_value):
		return {
			"success": false, 
			"data": "Warning: Property assignment executed, but value did not stick. " +
			"Expected: %s, Actual: %s. The property might be read-only or constrained by a setter." % [str(final_value), str(new_actual_val)]
		}
	
	return {"success": true, "data": "Property '%s' successfully set to %s" % [prop_name, str(final_value)]}


# --- 辅助函数 ---

func _is_type_compatible(target_type: int, value_type: int) -> bool:
	if target_type == value_type: return true
	if (target_type == TYPE_INT or target_type == TYPE_FLOAT) and (value_type == TYPE_INT or value_type == TYPE_FLOAT):
		return true
	if target_type == TYPE_OBJECT and value_type == TYPE_OBJECT:
		return true
	return false


func _is_value_approx_equal(a: Variant, b: Variant) -> bool:
	if a == null and b == null: return true
	if a == null or b == null: return false
	
	var type_a = typeof(a)
	var type_b = typeof(b)
	
	if not _is_type_compatible(type_a, type_b): return false
	
	match type_a:
		TYPE_FLOAT, TYPE_INT:
			return is_equal_approx(float(a), float(b))
		TYPE_VECTOR2:
			return a.is_equal_approx(b)
		TYPE_VECTOR3:
			return a.is_equal_approx(b)
		TYPE_COLOR:
			return a.is_equal_approx(b)
		TYPE_OBJECT:
			return a == b
		_:
			return a == b


func _convert_to_type(value: Variant, target_type: int) -> Variant:
	if typeof(value) == target_type:
		return value
		
	match target_type:
		TYPE_BOOL: return str(value).to_lower() == "true"
		TYPE_INT: return str(value).to_int()
		TYPE_FLOAT: return str(value).to_float()
		TYPE_STRING: return str(value)
		TYPE_STRING_NAME: return StringName(str(value))
		TYPE_VECTOR2:
			if value is Array and value.size() >= 2: return Vector2(value[0], value[1])
			if value is String:
				var parts = value.replace("(", "").replace(")", "").split(",")
				if parts.size() >= 2: return Vector2(parts[0].to_float(), parts[1].to_float())
		TYPE_VECTOR3:
			if value is Array and value.size() >= 3: return Vector3(value[0], value[1], value[2])
			if value is String:
				var parts = value.replace("(", "").replace(")", "").split(",")
				if parts.size() >= 3: return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
		TYPE_COLOR:
			if value is String: return Color(value)
		# [增强] 支持资源类型转换
		TYPE_OBJECT:
			if value is String:
				if value.begins_with("res://"):
					if ResourceLoader.exists(value):
						return ResourceLoader.load(value)
				elif ClassDB.class_exists(value):
					var obj = ClassDB.instantiate(value)
					return obj
	return value


func _try_infer_type_from_string(val_str: Variant) -> Variant:
	if not val_str is String: return val_str
	if val_str.begins_with("[") and val_str.ends_with("]"):
		var json = JSON.new()
		if json.parse(val_str) == OK:
			var arr = json.data
			if arr is Array:
				if arr.size() == 2: return Vector2(arr[0], arr[1])
				if arr.size() == 3: return Vector3(arr[0], arr[1], arr[2])
				if arr.size() == 4: return Color(arr[0], arr[1], arr[2], arr[3])
	if val_str.is_valid_float():
		if val_str.is_valid_int(): return val_str.to_int()
		return val_str.to_float()
	if val_str == "true": return true
	if val_str == "false": return false
	return val_str


func _get_type_name(type_int: int) -> String:
	match type_int:
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_COLOR: return "Color"
		TYPE_OBJECT: return "Resource/Object"
		_: return "Variant"
