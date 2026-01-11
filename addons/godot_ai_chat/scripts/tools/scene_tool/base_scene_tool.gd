@tool
extends AiTool
class_name BaseSceneTool

const PROPERTY_BLACKLIST = ["scale"]


func apply_properties(node: Node, props: Dictionary) -> void:
	for key in props:
		if key in PROPERTY_BLACKLIST: continue
		var target_type = TYPE_NIL
		
		# 尝试获取属性类型
		var prop_list = node.get_property_list()
		for p in prop_list:
			if p.name == key:
				target_type = p.type
				break
		
		var raw_val = props[key]
		var final_val = raw_val
		
		# 如果我们知道目标类型，尝试强制转换
		if target_type != TYPE_NIL:
			final_val = convert_to_type(raw_val, target_type)
		else:
			# 如果不知道目标类型（例如动态属性），尝试智能推断
			final_val = try_infer_type_from_string(raw_val)
		
		node.set(key, final_val)


func set_owner_recursive(node: Node, owner: Node):
	if node != owner:
		node.owner = owner
	
	if node != owner and not node.scene_file_path.is_empty():
		return
	
	for child in node.get_children():
		set_owner_recursive(child, owner)


# --- 通用类型处理函数 (来源于 set_node_property_tool) ---

func is_type_compatible(target_type: int, value_type: int) -> bool:
	if target_type == value_type:
		return true
	if (target_type == TYPE_INT or target_type == TYPE_FLOAT) and (value_type == TYPE_INT or value_type == TYPE_FLOAT):
		return true
	if target_type == TYPE_OBJECT and value_type == TYPE_OBJECT:
		return true
	return false


func is_value_approx_equal(a: Variant, b: Variant) -> bool:
	if a == null and b == null: return true
	if a == null or b == null: return false
	
	var type_a = typeof(a)
	var type_b = typeof(b)
	
	if not is_type_compatible(type_a, type_b): return false
	
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


func convert_to_type(value: Variant, target_type: int) -> Variant:
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
				var clean_str = value.replace("(", "").replace(")", "").replace("[", "").replace("]", "")
				var parts = clean_str.split(",")
				if parts.size() >= 2: return Vector2(parts[0].to_float(), parts[1].to_float())
		TYPE_VECTOR3:
			if value is Array and value.size() >= 3: return Vector3(value[0], value[1], value[2])
			if value is String:
				var clean_str = value.replace("(", "").replace(")", "").replace("[", "").replace("]", "")
				var parts = clean_str.split(",")
				if parts.size() >= 3: return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
		TYPE_COLOR:
			if value is Array and value.size() >= 3: 
				if value.size() == 4: return Color(value[0], value[1], value[2], value[3])
				return Color(value[0], value[1], value[2])
			if value is String:
				if "," in value:
					var clean_str = value.replace("(", "").replace(")", "").replace("[", "").replace("]", "")
					var parts = clean_str.split(",")
					if parts.size() >= 3:
						var r = parts[0].to_float()
						var g = parts[1].to_float()
						var b = parts[2].to_float()
						if parts.size() >= 4:
							return Color(r, g, b, parts[3].to_float())
						return Color(r, g, b)
				return Color(value)
		TYPE_OBJECT:
			if value is String:
				if value.begins_with("res://"):
					if ResourceLoader.exists(value):
						return ResourceLoader.load(value)
				# 增强：支持 new:ClassName
				elif value.begins_with("new:"):
					var type_name = value.substr(4)
					if ClassDB.class_exists(type_name):
						return ClassDB.instantiate(type_name)
				# 增强：支持直接 ClassName
				elif ClassDB.class_exists(value):
					return ClassDB.instantiate(value)
	return value


func try_infer_type_from_string(val_str: Variant) -> Variant:
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


func get_type_name(type_int: int) -> String:
	match type_int:
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
