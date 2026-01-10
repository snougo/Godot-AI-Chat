@tool
extends AiTool
class_name BaseSceneTool

const PROPERTY_BLACKLIST = ["scale"]


func apply_properties(node: Node, props: Dictionary) -> void:
	for key in props:
		if key in PROPERTY_BLACKLIST: continue
		var val = convert_value(node, key, props[key])
		node.set(key, val)


func convert_value(node: Node, property: String, value: Variant) -> Variant:
	var prop_list = node.get_property_list()
	var target_type = TYPE_NIL
	for p in prop_list:
		if p.name == property:
			target_type = p.type
			break
	
	if target_type == TYPE_NIL or typeof(value) == target_type:
		return value
	
	match target_type:
		TYPE_VECTOR3:
			if value is Array and value.size() == 3:
				return Vector3(value[0], value[1], value[2])
			if value is String:
				var parts = value.split(",")
				if parts.size() == 3:
					return Vector3(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
		TYPE_VECTOR2:
			if value is Array and value.size() >= 2:
				return Vector2(value[0], value[1])
		TYPE_COLOR:
			if value is String:
				return Color(value)
			if value is Array and value.size() >= 3:
				if value.size() == 4:
					return Color(value[0], value[1], value[2], value[3])
				else:
					return Color(value[0], value[1], value[2])
		TYPE_STRING_NAME:
			return StringName(str(value))
		TYPE_OBJECT:
			if value is String:
				# 增强功能 1: 加载资源路径
				if value.begins_with("res://"):
					if ResourceLoader.exists(value):
						return ResourceLoader.load(value, "", ResourceLoader.CACHE_MODE_IGNORE)
				# 增强功能 2: 实例化内置资源类 (如 "SphereMesh", "BoxShape3D")
				elif ClassDB.class_exists(value):
					var obj = ClassDB.instantiate(value)
					if obj is Resource:
						return obj
	return value


func set_owner_recursive(node: Node, owner: Node):
	if node != owner:
		node.owner = owner
	
	if node != owner and not node.scene_file_path.is_empty():
		return
	
	for child in node.get_children():
		set_owner_recursive(child, owner)
