@tool
extends BaseSceneTool

## 修改节点属性。
## 需要从 'get_current_active_scene' 获取 'node_path'。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "set_node_property"
	tool_description = "Modifies a node property. Using 'get_current_active_scene' before modifying."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": { 
				"type": "string", 
				"description": "Path to the node." 
			},
			"property_name": { 
				"type": "string", 
				"description": "Name of property (e.g. 'position', 'mesh:size'). Use ':' to access sub-resources." 
			},
			"value": { 
				"type": "string", 
				"description": "Value. For complex types, use JSON string (e.g. '[1, 2]'). For resources: 'res://path' or 'new:ClassName'." 
			}
		},
		"required": ["node_path", "property_name", "value"]
	}


## 执行设置节点属性操作
## [param p_args]: 包含 node_path、property_name 和 value 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Editor only."}
	
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return {"success": false, "data": "No active scene."}
	
	var path: String = p_args.get("node_path", "")
	var node: Node = root if path == "." else root.get_node_or_null(path)
	
	if not node:
		return {"success": false, "data": "Node not found: %s" % path}
	
	var prop_name: String = p_args.get("property_name", "")
	var raw_value: Variant = p_args.get("value")
	
	var validation_result: Dictionary = _check_property_validity(node, prop_name)
	if not validation_result.get("success", false):
		return validation_result
	
	var conversion_result: Dictionary = _convert_value(node, prop_name, raw_value)
	if not conversion_result.get("success", false):
		return conversion_result
	
	var final_value: Variant = conversion_result.final_value
	var current_val: Variant = conversion_result.current_val
	
	_execute_property_change(node, prop_name, current_val, final_value)
	
	return _verify_property_change(node, prop_name, final_value)


# --- Private Functions ---

## 检查属性是否存在且可修改
## [param p_node]: 目标节点
## [param p_prop_name]: 属性名称
## [return]: 验证结果字典
func _check_property_validity(p_node: Node, p_prop_name: String) -> Dictionary:
	var top_level_prop: String = p_prop_name
	if ":" in p_prop_name:
		top_level_prop = p_prop_name.split(":")[0]
	
	if top_level_prop in PROPERTY_BLACKLIST:
		return {"success": false, "data": "Error: Modification of property '%s' is not allowed." % p_prop_name}
	
	if not (top_level_prop in p_node):
		var found: bool = false
		for p in p_node.get_property_list():
			if p.name == top_level_prop:
				found = true
				break
		if not found:
			return {"success": false, "data": "Error: Property '%s' does not exist on node '%s' (%s)." % [top_level_prop, p_node.name, p_node.get_class()]}
	
	return {"success": true}


## 转换值类型
## [param p_node]: 目标节点
## [param p_prop_name]: 属性名称
## [param p_raw_value]: 原始值
## [return]: 包含 final_value 和 current_val 的字典
func _convert_value(p_node: Node, p_prop_name: String, p_raw_value: Variant) -> Dictionary:
	var current_val: Variant = p_node.get_indexed(p_prop_name)
	var final_value: Variant = p_raw_value
	var target_type: int = TYPE_NIL
	
	if current_val != null:
		target_type = typeof(current_val)
		final_value = convert_to_type(p_raw_value, target_type)
		
		var final_type: int = typeof(final_value)
		if not is_type_compatible(target_type, final_type):
			return {
				"success": false, 
				"data": "Error: Type mismatch for property '%s'. Expected %s, but got %s (parsed from '%s')." % 
				[p_prop_name, get_type_name(target_type), get_type_name(final_type), str(p_raw_value)]
			}
	else:
		final_value = try_infer_type_from_string(p_raw_value)
		var object_result: Dictionary = _handle_object_value(final_value)
		if not object_result.get("success", false):
			return object_result
		final_value = object_result.value
	
	return {"success": true, "final_value": final_value, "current_val": current_val}


## 处理对象类型的值
## [param p_value]: 值
## [return]: 包含 value 的字典
func _handle_object_value(p_value: Variant) -> Dictionary:
	if p_value is String:
		if p_value.begins_with("res://"):
			if ResourceLoader.exists(p_value):
				return {"success": true, "value": ResourceLoader.load(p_value)}
			else:
				return {"success": false, "data": "Error: Resource not found at '%s'." % p_value}
		else:
			var type_to_create: String = ""
			if p_value.begins_with("new:"):
				type_to_create = p_value.substr(4)
			elif ClassDB.class_exists(p_value):
				type_to_create = p_value
			
			if type_to_create != "":
				if ClassDB.class_exists(type_to_create):
					return {"success": true, "value": ClassDB.instantiate(type_to_create)}
				elif p_value.begins_with("new:"):
					return {"success": false, "data": "Error: Class '%s' does not exist." % type_to_create}
	
	return {"success": true, "value": p_value}


## 执行属性更改
## [param p_node]: 目标节点
## [param p_prop_name]: 属性名称
## [param p_current_val]: 当前值
## [param p_final_value]: 最终值
func _execute_property_change(p_node: Node, p_prop_name: String, p_current_val: Variant, p_final_value: Variant) -> void:
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("AI Set Property")
	
	if ":" in p_prop_name:
		undo_redo.add_do_method(p_node, "set_indexed", p_prop_name, p_final_value)
		undo_redo.add_undo_method(p_node, "set_indexed", p_prop_name, p_current_val)
	else:
		undo_redo.add_do_property(p_node, p_prop_name, p_final_value)
		undo_redo.add_undo_property(p_node, p_prop_name, p_current_val)
	
	undo_redo.commit_action()


## 验证属性更改是否成功
## [param p_node]: 目标节点
## [param p_prop_name]: 属性名称
## [param p_final_value]: 期望的最终值
## [return]: 验证结果字典
func _verify_property_change(p_node: Node, p_prop_name: String, p_final_value: Variant) -> Dictionary:
	var new_actual_val: Variant = p_node.get_indexed(p_prop_name)
	
	if not is_value_approx_equal(new_actual_val, p_final_value):
		return {
			"success": false, 
			"data": "Warning: Property assignment executed, but value did not stick. " +
			"Expected: %s, Actual: %s. The property might be read-only or constrained by a setter." % [str(p_final_value), str(new_actual_val)]
		}
	
	return {"success": true, "data": "Property '%s' successfully set to %s" % [p_prop_name, str(p_final_value)]}
