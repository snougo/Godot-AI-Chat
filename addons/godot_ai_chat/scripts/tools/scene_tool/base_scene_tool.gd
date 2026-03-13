@tool
class_name BaseSceneTool
extends AiTool

## 场景工具的基类。
## 提供节点属性应用、类型转换、场景树遍历和常用获取逻辑的通用功能。

# --- Enums / Constants ---

## 属性黑名单，禁止修改的属性
const PROPERTY_BLACKLIST: Array[String] = ["scale"]


# --- Public Functions ---

## 获取当前活跃的编辑场景根节点
## [return]: 根节点，如果失败返回 null
func get_active_scene_root() -> Node:
	if not Engine.is_editor_hint():
		return null
	return EditorInterface.get_edited_scene_root()


## 根据路径从根节点获取目标节点
## [param p_root]: 场景根节点
## [param p_path]: 节点路径，支持以下格式：
##   - "." 表示根节点
##   - "NodeName" 仅节点名（场景内唯一时可用）
##   - "Parent/Child" 相对路径（推荐）
##   - "/Root/Child" 绝对路径（可选前缀 '/'，但不强制）
## [return]: 目标节点，如果未找到返回 null
func get_node_from_root(p_root: Node, p_path: String) -> Node:
	if p_path.is_empty() or p_path == "." or p_path == "/":
		return p_root
	
	# 清理路径前缀，统一处理
	var target_path: String = p_path
	
	# 仅移除"./"前缀，保留"/"和根节点名格式
	if target_path.begins_with("./"):
		target_path = target_path.substr(2)
	
	# 如果清理后为空，返回根节点
	if target_path.is_empty():
		return p_root
	
	# 检查路径是否匹配根节点名称（支持两种格式）
	if target_path == p_root.name or (p_root.name.begins_with("/") and target_path == p_root.name.substr(1)):
		return p_root
	
	# 尝试直接使用 get_node_or_null（标准 Godot NodePath，支持"/Root/Child"）
	var node = p_root.get_node_or_null(target_path)
	if node:
		return node
	
	# 如果直接查找失败，尝试用节点名模糊匹配（仅当路径不含 "/" 时）
	if not target_path.contains("/"):
		var found_node = _find_node_by_name(p_root, target_path)
		if found_node:
			return found_node
	
	return null


## 递归获取节点的完整属性（包括 Resource 内部属性）
func get_all_node_properties(p_node: Node) -> Dictionary:
	var properties := {}
	var prop_list := p_node.get_property_list()
	
	for p in prop_list:
		if not (p.usage & PROPERTY_USAGE_EDITOR):
			continue
		
		var value = p_node.get(p.name)
		
		if value is Resource:
			properties[p.name] = {
				"value": str(value),
				"type": p.type,
				"properties": _get_resource_properties_recursive(value)
			}
		else:
			properties[p.name] = {
				"value": str(value),
				"type": p.type,
			}
	
	return properties


## 将属性字典应用到节点
## [param p_node]: 目标节点
## [param p_props]: 属性字典
func apply_properties(p_node: Node, p_props: Dictionary) -> void:
	for key in p_props:
		if key in PROPERTY_BLACKLIST:
			continue
		
		var target_type: int = TYPE_NIL
		var prop_list: Array[Dictionary] = p_node.get_property_list()
		
		for p in prop_list:
			if p.name == key:
				target_type = p.type
				break
		
		var raw_val: Variant = p_props[key]
		var final_val: Variant = raw_val
		
		if target_type != TYPE_NIL:
			final_val = convert_to_type_with_validation(raw_val, target_type)
		else:
			final_val = try_infer_type_from_string(raw_val)
		
		p_node.set(key, final_val)


## 递归设置节点的 owner
## [param p_node]: 要设置的节点
## [param p_owner]: 目标 owner
func set_owner_recursive(p_node: Node, p_owner: Node) -> void:
	if p_node != p_owner:
		p_node.owner = p_owner
	
	if p_node != p_owner and not p_node.scene_file_path.is_empty():
		return
	
	for child in p_node.get_children():
		set_owner_recursive(child, p_owner)


## 获取场景树结构的字符串表示
## [param p_root]: 根节点
## [return]: 场景树字符串
func get_scene_tree_string(p_root: Node) -> String:
	var lines: PackedStringArray = []
	_traverse_node(p_root, p_root, 0, lines)
	return "\n".join(lines)


## 获取所有节点的路径列表（用于 AI 参考）
## [param p_root]: 根节点
## [return]: 路径字符串数组
func get_all_node_paths(p_root: Node) -> Array[String]:
	var paths: Array[String] = []
	_collect_node_paths(p_root, p_root, ".", paths)
	return paths


## 根据类型字符串实例化节点
## [param p_type_str]: 类名 (如 "Node3D") 或 资源路径 (如 "res://player.tscn")
## [return]: 实例化后的节点，失败返回 null
func instantiate_node_from_type(p_type_str: String) -> Node:
	if p_type_str.begins_with("res://"):
		if ResourceLoader.exists(p_type_str):
			var res = load(p_type_str)
			if res is PackedScene:
				return res.instantiate()
	elif ClassDB.class_exists(p_type_str):
		var instance = ClassDB.instantiate(p_type_str)
		if instance is Node:
			return instance
		else:
			# Resource 不是 Node，返回 null
			return null
	
	return null


## 检查属性在节点上是否有效
func is_prop_valid(node: Node, prop: String) -> bool:
	var base = prop.split(":")[0]
	return (base in node) or has_editor_prop(node, base)


## 检查是否包含编辑器属性
func has_editor_prop(node: Node, prop: String) -> bool:
	for p in node.get_property_list():
		if p.name == prop:
			return true
	return false


## 检查类型是否兼容
## [param p_target_type]: 目标类型
## [param p_value_type]: 值类型
## [return]: 是否兼容
func is_type_compatible(p_target_type: int, p_value_type: int) -> bool:
	if p_target_type == p_value_type:
		return true
	if (p_target_type == TYPE_INT or p_target_type == TYPE_FLOAT) and (p_value_type == TYPE_INT or p_value_type == TYPE_FLOAT):
		return true
	if p_target_type == TYPE_OBJECT and p_value_type == TYPE_OBJECT:
		return true
	return false


## 检查两个值是否近似相等
## [param p_a]: 第一个值
## [param p_b]: 第二个值
## [return]: 是否近似相等
func is_value_approx_equal(p_a: Variant, p_b: Variant) -> bool:
	if p_a == null and p_b == null:
		return true
	if p_a == null or p_b == null:
		return false
	
	var type_a: int = typeof(p_a)
	var type_b: int = typeof(p_b)
	
	if not is_type_compatible(type_a, type_b):
		return false
	
	match type_a:
		TYPE_FLOAT, TYPE_INT:
			return is_equal_approx(float(p_a), float(p_b))
		TYPE_VECTOR2:
			return p_a.is_equal_approx(p_b)
		TYPE_VECTOR3:
			return p_a.is_equal_approx(p_b)
		TYPE_COLOR:
			return p_a.is_equal_approx(p_b)
		TYPE_OBJECT:
			return p_a == p_b
		_:
			return p_a == p_b


## 将值转换为目标类型，返回字典包含结果和错误信息
## [param p_value]: 原始值
## [param p_target_type]: 目标类型
## [return]: {"success": bool, "value": Variant, "error": String}
func convert_to_type_with_validation(p_value: Variant, p_target_type: int) -> Dictionary:
	if typeof(p_value) == p_target_type:
		return {"success": true, "value": p_value, "error": ""}
	
	var result: Variant = p_value
	var error_msg: String = ""
	
	match p_target_type:
		TYPE_BOOL:
			if p_value is String:
				var lower_val = p_value.to_lower()
				if lower_val in ["true", "false", "1", "0", "yes", "no", "on", "off"]:
					result = lower_val in ["true", "1", "yes", "on"]
				else:
					error_msg = "Cannot convert '%s' to bool. Expected: true/false." % p_value
			else:
				error_msg = "Cannot convert %s to bool." % str(p_value)
		
		TYPE_INT:
			if p_value is String:
				if p_value.is_valid_int():
					result = p_value.to_int()
				else:
					error_msg = "Cannot convert '%s' to int." % p_value
			elif p_value is float:
				result = int(p_value)
			else:
				error_msg = "Cannot convert %s to int." % str(p_value)
		
		TYPE_FLOAT:
			if p_value is String:
				if p_value.is_valid_float():
					result = p_value.to_float()
				else:
					error_msg = "Cannot convert '%s' to float." % p_value
			elif p_value is int:
				result = float(p_value)
			else:
				error_msg = "Cannot convert %s to float." % str(p_value)
		
		TYPE_STRING:
			result = str(p_value)
		
		TYPE_STRING_NAME:
			result = StringName(str(p_value))
		
		TYPE_VECTOR2:
			var conversion = _convert_to_vector2_with_validation(p_value)
			if conversion.success:
				result = conversion.value
			else:
				error_msg = conversion.error
		
		TYPE_VECTOR3:
			var conversion = _convert_to_vector3_with_validation(p_value)
			if conversion.success:
				result = conversion.value
			else:
				error_msg = conversion.error
		
		TYPE_COLOR:
			var conversion = _convert_to_color_with_validation(p_value)
			if conversion.success:
				result = conversion.value
			else:
				error_msg = conversion.error
		
		TYPE_OBJECT:
			var conversion = _convert_to_object_with_validation(p_value)
			if conversion.success:
				result = conversion.value
			else:
				error_msg = conversion.error
		
		_:
			# 其他类型，尝试直接返回原值
			result = p_value
	
	return {
		"success": error_msg.is_empty(),
		"value": result,
		"error": error_msg
	}


## 从字符串推断类型
## [param p_val_str]: 字符串值
## [return]: 推断后的值
func try_infer_type_from_string(p_val_str: Variant) -> Variant:
	if not p_val_str is String:
		return p_val_str
	
	if p_val_str.begins_with("[") and p_val_str.ends_with("]"):
		var json := JSON.new()
		if json.parse(p_val_str) == OK and json.data is Array:
			var arr: Array = json.data
			if arr.size() == 2:
				return Vector2(arr[0], arr[1])
			if arr.size() == 3:
				return Vector3(arr[0], arr[1], arr[2])
			if arr.size() == 4:
				return Color(arr[0], arr[1], arr[2], arr[3])
	
	if p_val_str.is_valid_float():
		if p_val_str.is_valid_int():
			return p_val_str.to_int()
		return p_val_str.to_float()
	
	if p_val_str == "true":
		return true
	if p_val_str == "false":
		return false
	
	return p_val_str


## 获取类型名称
func get_type_name(p_type_int: int) -> String:
	match p_type_int:
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_RECT2: return "Rect2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_COLOR: return "Color"
		TYPE_OBJECT: return "Resource/Object"
		TYPE_ARRAY: return "Array"
		TYPE_DICTIONARY: return "Dictionary"
		_: return "Variant"


## 查找相似的节点路径（用于错误提示）
## [param p_root]: 根节点
## [param p_input_path]: 用户输入的路径
## [return]: 相似路径列表
func find_similar_paths(p_root: Node, p_input_path: String) -> Array[String]:
	var similar_paths: Array[String] = []
	var input_lower: String = p_input_path.to_lower()
	
	# 检查根节点
	if p_root.name.to_lower().contains(input_lower) or input_lower.contains(p_root.name.to_lower()):
		similar_paths.append(".")
	
	# 递归检查子节点
	_collect_similar_paths(p_root, p_root.name, input_lower, similar_paths)
	
	return similar_paths


## 生成节点路径错误提示信息（供 AI 参考）
## [param p_root]: 根节点
## [param p_input_path]: 用户输入的错误路径
## [return]: 格式化的错误提示字符串
func get_node_path_error_hint(p_root: Node, p_input_path: String) -> String:
	var all_paths = get_all_node_paths(p_root)
	var hint = "❌ Node not found: '%s'\n\n" % p_input_path
	hint += "📋 Available node paths (use one of these formats):\n"
	for path in all_paths:
		hint += "   • %s\n" % path
	
	var similar = find_similar_paths(p_root, p_input_path)
	if not similar.is_empty():
		hint += "\n💡 Did you mean:\n"
		for s in similar:
			hint += "   • %s\n" % s
	
	hint += "\n📝 Path format tips:\n"
	hint += "   • '.' = root node\n"
	hint += "   • 'NodeName' = node name (if unique)\n"
	hint += "   • 'Parent/Child' = relative path (recommended)\n"
	hint += "   • '/Root/Child' = absolute path from root\n"
	
	return hint


# --- Private Functions ---

func _find_node_by_name(p_node: Node, p_name: String) -> Node:
	# 先检查当前节点
	if p_node.name == p_name:
		return p_node
	
	# 递归检查子节点
	for child in p_node.get_children():
		var found = _find_node_by_name(child, p_name)
		if found:
			return found
	
	return null


func _collect_node_paths(p_node: Node, p_root: Node, p_current_path: String, p_paths: Array[String]) -> void:
	# 添加到列表
	if p_current_path != ".":
		p_paths.append(p_current_path)
	
	# 如果是外部场景实例，不再深入
	if p_node != p_root and not p_node.scene_file_path.is_empty():
		return
	
	# 递归收集子节点
	for child in p_node.get_children():
		var child_path: String
		if p_current_path == ".":
			child_path = child.name
		else:
			child_path = p_current_path + "/" + child.name
		_collect_node_paths(child, p_root, child_path, p_paths)


func _get_resource_properties_recursive(resource: Object) -> Dictionary:
	var props := {}
	for p in resource.get_property_list():
		if (p.usage & PROPERTY_USAGE_EDITOR):
			props[p.name] = str(resource.get(p.name))
	return props


func _traverse_node(node: Node, root: Node, depth: int, lines: PackedStringArray):
	if node != root and node.owner != root:
		return
	var indent = "  ".repeat(depth)
	var extra_info: String = ""
	
	# Add script info if present
	var script = node.get_script()
	if script:
		var script_path: String = script.resource_path  # 显示完整路径
		extra_info += " Attached Script: 📜" + script_path
	
	lines.append("%s- %s (%s)%s" % [indent, node.name, node.get_class(), extra_info])
	for c in node.get_children():
		_traverse_node(c, root, depth + 1, lines)


# 递归收集相似路径
func _collect_similar_paths(p_node: Node, p_current_path: String, p_input_lower: String, p_results: Array[String]) -> void:
	for child in p_node.get_children():
		var child_path: String = p_current_path + "/" + child.name
		
		# 检查节点名称是否相似
		if child.name.to_lower().contains(p_input_lower) or p_input_lower.contains(child.name.to_lower()):
			p_results.append(child_path.trim_prefix(p_node.name + "/"))
		
		# 递归检查子节点
		_collect_similar_paths(child, child_path, p_input_lower, p_results)


# 带验证的 Vector2 转换
func _convert_to_vector2_with_validation(p_value: Variant) -> Dictionary:
	if p_value is Vector2:
		return {"success": true, "value": p_value, "error": ""}
	
	if p_value is Array:
		if p_value.size() >= 2:
			return {"success": true, "value": Vector2(p_value[0], p_value[1]), "error": ""}
		else:
			return {"success": false, "value": null, "error": "Vector2 requires 2 values, got %d." % p_value.size()}
	
	if p_value is String:
		var clean_str: String = p_value.replace("(", "").replace(")", "").replace("[", "").replace("]", "").strip_edges()
		var parts: PackedStringArray = clean_str.split(",")
		if parts.size() >= 2:
			var x_valid = parts[0].strip_edges().is_valid_float()
			var y_valid = parts[1].strip_edges().is_valid_float()
			if x_valid and y_valid:
				return {"success": true, "value": Vector2(parts[0].to_float(), parts[1].to_float()), "error": ""}
			else:
				return {"success": false, "value": null, "error": "Invalid Vector2 format: '%s'. Expected: '[x, y]' or 'x, y' with numeric values." % p_value}
		else:
			return {"success": false, "value": null, "error": "Invalid Vector2 format: '%s'. Expected: '[x, y]' or 'x, y'." % p_value}
	
	return {"success": false, "value": null, "error": "Cannot convert %s to Vector2." % str(p_value)}


# 带验证的 Vector3 转换
func _convert_to_vector3_with_validation(p_value: Variant) -> Dictionary:
	if p_value is Vector3:
		return {"success": true, "value": p_value, "error": ""}
	
	if p_value is Array:
		if p_value.size() >= 3:
			return {"success": true, "value": Vector3(p_value[0], p_value[1], p_value[2]), "error": ""}
		else:
			return {"success": false, "value": null, "error": "Vector3 requires 3 values, got %d." % p_value.size()}
	
	if p_value is String:
		var clean_str: String = p_value.replace("(", "").replace(")", "").replace("[", "").replace("]", "").strip_edges()
		var parts: PackedStringArray = clean_str.split(",")
		if parts.size() >= 3:
			var x_valid = parts[0].strip_edges().is_valid_float()
			var y_valid = parts[1].strip_edges().is_valid_float()
			var z_valid = parts[2].strip_edges().is_valid_float()
			if x_valid and y_valid and z_valid:
				return {"success": true, "value": Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float()), "error": ""}
			else:
				return {"success": false, "value": null, "error": "Invalid Vector3 format: '%s'. Expected: '[x, y, z]' or 'x, y, z' with numeric values." % p_value}
		else:
			return {"success": false, "value": null, "error": "Invalid Vector3 format: '%s'. Expected: '[x, y, z]' or 'x, y, z'." % p_value}
	
	return {"success": false, "value": null, "error": "Cannot convert %s to Vector3." % str(p_value)}


# 带验证的 Color 转换
func _convert_to_color_with_validation(p_value: Variant) -> Dictionary:
	if p_value is Color:
		return {"success": true, "value": p_value, "error": ""}
	
	if p_value is Array:
		if p_value.size() == 3:
			return {"success": true, "value": Color(p_value[0], p_value[1], p_value[2]), "error": ""}
		elif p_value.size() == 4:
			return {"success": true, "value": Color(p_value[0], p_value[1], p_value[2], p_value[3]), "error": ""}
		else:
			return {"success": false, "value": null, "error": "Color requires 3 or 4 values (RGB or RGBA), got %d." % p_value.size()}
	
	if p_value is String:
		# 检查是否是颜色名称或十六进制
		if p_value.begins_with("#") or p_value.is_valid_html_color():
			return {"success": true, "value": Color(p_value), "error": ""}
		
		var clean_str: String = p_value.replace("(", "").replace(")", "").replace("[", "").replace("]", "").strip_edges()
		var parts: PackedStringArray = clean_str.split(",")
		if parts.size() >= 3:
			var r_valid = parts[0].strip_edges().is_valid_float()
			var g_valid = parts[1].strip_edges().is_valid_float()
			var b_valid = parts[2].strip_edges().is_valid_float()
			var a_valid = true
			if parts.size() >= 4:
				a_valid = parts[3].strip_edges().is_valid_float()
			
			if r_valid and g_valid and b_valid and a_valid:
				var r: float = parts[0].to_float()
				var g: float = parts[1].to_float()
				var b: float = parts[2].to_float()
				if parts.size() >= 4:
					return {"success": true, "value": Color(r, g, b, parts[3].to_float()), "error": ""}
				return {"success": true, "value": Color(r, g, b), "error": ""}
			else:
				return {"success": false, "value": null, "error": "Invalid Color format: '%s'. Expected: '[r, g, b]' or '[r, g, b, a]' with numeric values 0-1 or 0-255." % p_value}
		else:
			return {"success": false, "value": null, "error": "Invalid Color format: '%s'. Expected: '[r, g, b]' or '[r, g, b, a]'." % p_value}
	
	return {"success": false, "value": null, "error": "Cannot convert %s to Color." % str(p_value)}


# 带验证的 Object 转换
func _convert_to_object_with_validation(p_value: Variant) -> Dictionary:
	if p_value is Object:
		return {"success": true, "value": p_value, "error": ""}
	
	if p_value is String:
		if p_value.begins_with("res://"):
			if ResourceLoader.exists(p_value):
				return {"success": true, "value": ResourceLoader.load(p_value), "error": ""}
			else:
				return {"success": false, "value": null, "error": "Resource not found: '%s'." % p_value}
		elif p_value.begins_with("new:"):
			var type_name: String = p_value.substr(4)
			if ClassDB.class_exists(type_name):
				return {"success": true, "value": ClassDB.instantiate(type_name), "error": ""}
			else:
				return {"success": false, "value": null, "error": "Class does not exist: '%s'." % type_name}
		elif p_value.to_lower() == "null":
			return {"success": true, "value": null, "error": ""}
		elif ClassDB.class_exists(p_value):
			return {"success": true, "value": ClassDB.instantiate(p_value), "error": ""}
		else:
			return {"success": false, "value": null, "error": "Invalid object value: '%s'. Expected: 'res://path', 'new:ClassName', 'null', or valid class name." % p_value}
	
	return {"success": false, "value": null, "error": "Cannot convert %s to Object." % str(p_value)}
