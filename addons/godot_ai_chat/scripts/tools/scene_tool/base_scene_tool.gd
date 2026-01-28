@tool
class_name BaseSceneTool
extends AiTool

## 场景工具的基类。
## 提供节点属性应用、类型转换和场景树遍历的通用功能。

# --- Enums / Constants ---

## 属性黑名单，禁止修改的属性
const PROPERTY_BLACKLIST: Array[String] = ["scale"]


# --- Public Functions ---

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
			final_val = convert_to_type(raw_val, target_type)
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


## 将值转换为目标类型
## [param p_value]: 原始值
## [param p_target_type]: 目标类型
## [return]: 转换后的值
func convert_to_type(p_value: Variant, p_target_type: int) -> Variant:
	if typeof(p_value) == p_target_type:
		return p_value
	
	match p_target_type:
		TYPE_BOOL:
			return str(p_value).to_lower() == "true"
		TYPE_INT:
			return str(p_value).to_int()
		TYPE_FLOAT:
			return str(p_value).to_float()
		TYPE_STRING:
			return str(p_value)
		TYPE_STRING_NAME:
			return StringName(str(p_value))
		TYPE_VECTOR2:
			return _convert_to_vector2(p_value)
		TYPE_VECTOR3:
			return _convert_to_vector3(p_value)
		TYPE_COLOR:
			return _convert_to_color(p_value)
		TYPE_OBJECT:
			return _convert_to_object(p_value)
		_:
			return p_value


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
## [param p_type_int]: 类型整数
## [return]: 类型名称字符串
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

# --- Private Functions ---

func _traverse_node(node: Node, root: Node, depth: int, lines: PackedStringArray):
	if node != root and node.owner != root:
		return
	var indent = "  ".repeat(depth)
	lines.append("%s- %s (%s)" % [indent, node.name, node.get_class()])
	for c in node.get_children():
		_traverse_node(c, root, depth + 1, lines)


## 转换为 Vector2
## [param p_value]: 原始值
## [return]: Vector2 值
func _convert_to_vector2(p_value: Variant) -> Variant:
	if p_value is Array and p_value.size() >= 2:
		return Vector2(p_value[0], p_value[1])
	if p_value is String:
		var clean_str: String = p_value.replace("(", "").replace(")", "").replace("[", "").replace("]", "")
		var parts: PackedStringArray = clean_str.split(",")
		if parts.size() >= 2:
			return Vector2(parts[0].to_float(), parts[1].to_float())
	return p_value


## 转换为 Vector3
## [param p_value]: 原始值
## [return]: Vector3 值
func _convert_to_vector3(p_value: Variant) -> Variant:
	if p_value is Array and p_value.size() >= 3:
		return Vector3(p_value[0], p_value[1], p_value[2])
	if p_value is String:
		var clean_str: String = p_value.replace("(", "").replace(")", "").replace("[", "").replace("]", "")
		var parts: PackedStringArray = clean_str.split(",")
		if parts.size() >= 3:
			return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
	return p_value


## 转换为 Color
## [param p_value]: 原始值
## [return]: Color 值
func _convert_to_color(p_value: Variant) -> Variant:
	if p_value is Array and p_value.size() >= 3:
		if p_value.size() == 4:
			return Color(p_value[0], p_value[1], p_value[2], p_value[3])
		return Color(p_value[0], p_value[1], p_value[2])
	if p_value is String:
		if "," in p_value:
			var clean_str: String = p_value.replace("(", "").replace(")", "").replace("[", "").replace("]", "")
			var parts: PackedStringArray = clean_str.split(",")
			if parts.size() >= 3:
				var r: float = parts[0].to_float()
				var g: float = parts[1].to_float()
				var b: float = parts[2].to_float()
				if parts.size() >= 4:
					return Color(r, g, b, parts[3].to_float())
				return Color(r, g, b)
		return Color(p_value)
	return p_value


## 转换为 Object
## [param p_value]: 原始值
## [return]: Object 值
func _convert_to_object(p_value: Variant) -> Variant:
	if p_value is String:
		if p_value.begins_with("res://"):
			if ResourceLoader.exists(p_value):
				return ResourceLoader.load(p_value)
		elif p_value.begins_with("new:"):
			var type_name: String = p_value.substr(4)
			if ClassDB.class_exists(type_name):
				return ClassDB.instantiate(type_name)
		elif ClassDB.class_exists(p_value):
			return ClassDB.instantiate(p_value)
	return p_value
