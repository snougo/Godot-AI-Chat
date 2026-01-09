@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "scene_set_property"
	tool_description = "Set a property value on a node. Supports basic types, resources (res://), creating new resources (new:ClassName), and sub-properties (e.g. 'mesh:size')."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": { "type": "string", "description": "Path to the node." },
			"property_name": { "type": "string", "description": "Name of property (e.g. 'position', 'text', 'mesh:size')." },
			"value": { "type": "string", "description": "Value. For complex types, use JSON string. For resources: 'res://path'. For new resource: 'new:BoxShape3D'." }
		},
		"required": ["node_path", "property_name", "value"]
	}


func execute(args: Dictionary, _context_provider: Object) -> Dictionary:
	if not Engine.is_editor_hint(): return {"success": false, "data": "Editor only."}
	
	var root = EditorInterface.get_edited_scene_root()
	if not root: return {"success": false, "data": "No active scene."}
	
	var path = args.get("node_path", "")
	var node = root if path == "." else root.get_node_or_null(path)
	if not node: return {"success": false, "data": "Node not found."}
	
	var prop_name = args.get("property_name", "")
	var raw_value = args.get("value")
	
	# 1. 预处理值 (解析 new: 或 res://)
	var final_value = _parse_value_string(raw_value)
	
	# 2. 尝试转换类型
	if final_value is String:
		final_value = _try_infer_type(final_value)

	# 3. 执行设置 (set_indexed 支持嵌套属性，如 mesh:size)
	node.set_indexed(prop_name, final_value)
	
	# 4. 标记脏
	var undo_redo = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("AI Set Property")
	undo_redo.add_do_property(root, "name", root.name)
	undo_redo.add_undo_property(root, "name", root.name)
	undo_redo.commit_action()
	
	return {"success": true, "data": "Property '%s' set to %s" % [prop_name, str(final_value)]}


func _parse_value_string(val: Variant) -> Variant:
	if not val is String: return val
	
	if val.begins_with("new:"):
		var type_name = val.substr(4) # 变量名已修正，避开关键字
		if ClassDB.class_exists(type_name):
			var obj = ClassDB.instantiate(type_name)
			return obj
	elif val.begins_with("res://"):
		if ResourceLoader.exists(val):
			return ResourceLoader.load(val)
	return val


func _try_infer_type(val_str: String) -> Variant:
	# 简单的类型推断
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
