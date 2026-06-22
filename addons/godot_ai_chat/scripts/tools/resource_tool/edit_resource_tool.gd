@tool
extends AiTool

## 资源文件编辑工具。
## 用于编辑已存在的 .tres/.res 资源文件的属性。
## 加载现有资源 → 设置属性 → 重新保存。
## 支持简单属性（int, float, bool, String, Color, Vector2, Vector3）和
## 资源引用属性（res:// 路径）。


# --- Enums / Constants ---

const RESOURCE_EXTENSIONS: Array[String] = ["tres", "res"]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "edit_resource"
	tool_description = "Edits properties of an existing Resource (.tres/.res) file."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Full path to the existing .tres or .res file (e.g., 'res://materials/stone.tres')."
			},
			"properties": {
				"type": "object",
				"description": "Dictionary of property names and their new values. Supports nested properties via ':' separator (e.g., {'albedo_color': 'Color(1,0,0,1)', 'normal_enabled': true, 'albedo_texture': 'res://textures/stone_albedo.png'})."
			}
		},
		"required": ["path", "properties"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var file_path: String = p_args.get("path", "").strip_edges()
	if file_path.is_empty():
		return {"success": false, "data": "Error: 'path' is required."}

	# 安全校验
	var safety_err: String = validate_path_safety(file_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}

	# 检查文件是否存在
	if not FileAccess.file_exists(file_path):
		return {"success": false, "data": "Error: File not found at %s." % file_path}

	# 校验扩展名
	var ext: String = file_path.get_extension().to_lower()
	if ext not in RESOURCE_EXTENSIONS:
		return {"success": false, "data": "Error: Invalid extension '.%s'. Resource files must use: .tres or .res." % ext}

	# 加载资源
	var resource: Resource = load(file_path)
	if not resource:
		return {"success": false, "data": "Error: Failed to load resource from %s." % file_path}

	var properties_raw: Variant = p_args.get("properties", {})
	if not (properties_raw is Dictionary):
		return {"success": false, "data": "Error: 'properties' must be a dictionary (object), got %s." % typeof(properties_raw)}
	var properties: Dictionary = properties_raw as Dictionary
	if properties.is_empty():
		return {"success": false, "data": "Error: 'properties' is required and cannot be empty."}


	# 记录变更
	var changes: Array[String] = []
	var errors: Array[String] = []

	for prop_name in properties:
		var raw_val: Variant = properties[prop_name]
		var result: Dictionary = _set_resource_property(resource, prop_name, raw_val)
		if result.get("success", false):
			changes.append("%s → %s" % [prop_name, str(result.get("resolved_value", raw_val))])
		else:
			errors.append(result.get("error", "Unknown error setting '%s'." % prop_name))

	if not errors.is_empty():
		return {
			"success": false,
			"data": "Failed to set some properties:\n" + "\n".join(errors)
		}

	# 保存资源
	var save_err: Error = ResourceSaver.save(resource, file_path)
	if save_err != OK:
		return {"success": false, "data": "Error: Failed to save resource. Error code: %d" % save_err}

	ToolBox.update_editor_filesystem(file_path)

	return {
		"success": true,
		"data": "Resource updated: %s\nChanges applied:\n  %s" % [file_path, "\n  ".join(changes)]
	}


# --- Private Functions ---

# 设置资源上的一个属性，自动处理类型转换
# [param p_resource]: 目标资源对象
# [param p_prop_name]: 属性名（支持 ":" 嵌套路径）
# [param p_raw_value]: 原始值
# [return]: {"success": bool, "resolved_value": Variant, "error": String}
func _set_resource_property(p_resource: Resource, p_prop_name: String, p_raw_value: Variant) -> Dictionary:
	# 确定目标类型
	var target_type: int = TYPE_NIL
	var found: bool = false

	if ":" in p_prop_name:
		# 嵌套属性，从当前值推断类型
		var current: Variant = p_resource.get_indexed(p_prop_name)
		if current != null:
			target_type = typeof(current)
			found = true
	else:
		for prop in p_resource.get_property_list():
			if prop.name == p_prop_name:
				target_type = prop.type
				found = true
				break

	if not found:
		# 检查属性是否存在
		if p_prop_name in p_resource:
			var current_val: Variant = p_resource[p_prop_name]
			target_type = typeof(current_val)
			found = true

	if not found:
		return {"success": false, "error": "Property '%s' not found on resource type '%s'." % [p_prop_name, p_resource.get_class()], "resolved_value": null}

	# 类型转换
	var final_val: Variant = _coerce_value(p_raw_value, target_type)
	if final_val == null and p_raw_value != null:
		return {"success": false, "error": "Failed to convert value for '%s'. Expected type: %s" % [p_prop_name, _type_name(target_type)], "resolved_value": null}

	# 特殊处理 Texture 等资源引用
	if target_type == TYPE_OBJECT and final_val is String:
		var path_str: String = final_val as String
		if path_str.begins_with("res://"):
			if ResourceLoader.exists(path_str):
				final_val = load(path_str)
			else:
				return {"success": false, "error": "Resource not found at '%s'." % path_str, "resolved_value": null}

	# 应用属性
	if ":" in p_prop_name:
		p_resource.set_indexed(p_prop_name, final_val)
	else:
		p_resource.set(p_prop_name, final_val)

	return {"success": true, "resolved_value": final_val}


# 将值转换为目标类型
# [param p_value]: 原始值
# [param p_target_type]: 目标类型枚举
# [return]: 转换后的值，失败返回 null
func _coerce_value(p_value: Variant, p_target_type: int) -> Variant:
	if typeof(p_value) == p_target_type:
		return p_value

	# String 输入 → 目标类型
	if p_value is String:
		var str_val: String = (p_value as String).strip_edges()

		match p_target_type:
			TYPE_BOOL:
				var lower: String = str_val.to_lower()
				if lower in ["true", "1", "yes", "on"]:
					return true
				elif lower in ["false", "0", "no", "off"]:
					return false
				return null

			TYPE_INT:
				if str_val.is_valid_int():
					return str_val.to_int()
				return null

			TYPE_FLOAT:
				if str_val.is_valid_float():
					return str_val.to_float()
				return null

			TYPE_STRING, TYPE_STRING_NAME:
				return str_val

			TYPE_VECTOR2:
				var arr: Array = _parse_numeric_array(str_val)
				if arr.size() >= 2:
					return Vector2(arr[0], arr[1])
				return null

			TYPE_VECTOR3:
				var arr: Array = _parse_numeric_array(str_val)
				if arr.size() >= 3:
					return Vector3(arr[0], arr[1], arr[2])
				return null

			TYPE_COLOR:
				# 尝试 Color 构造函数风格
				if str_val.begins_with("Color("):
					var inner: String = str_val.substr(6, str_val.length() - 7)
					var parts: PackedStringArray = inner.split(",")
					if parts.size() == 3:
						return Color(parts[0].to_float(), parts[1].to_float(), parts[2].to_float())
					if parts.size() == 4:
						return Color(parts[0].to_float(), parts[1].to_float(), parts[2].to_float(), parts[3].to_float())
				# 十六进制
				if str_val.begins_with("#"):
					return Color(str_val)
				# 数值数组
				var arr: Array = _parse_numeric_array(str_val)
				if arr.size() == 3:
					return Color(arr[0], arr[1], arr[2])
				if arr.size() == 4:
					return Color(arr[0], arr[1], arr[2], arr[3])
				return null

			TYPE_OBJECT:
				# 保持字符串，由调用方处理资源路径加载
				return str_val

	# int → float 或 float → int
	if p_target_type == TYPE_FLOAT and p_value is int:
		return float(p_value)
	if p_target_type == TYPE_INT and p_value is float:
		return int(p_value)

	# bool 的 JSON 兼容
	if p_target_type == TYPE_BOOL:
		if p_value is bool:
			return p_value
		return null

	return p_value


# 从字符串解析数值数组
# 支持格式: "[1, 2, 3]" 或 "1, 2, 3" 或 "Vector3(1, 2, 3)"
func _parse_numeric_array(p_str: String) -> Array:
	var cleaned: String = p_str
	# 移除常见包装: Vector2/3(...), Color(...), [...]
	cleaned = cleaned.replace("Vector2(", "").replace("Vector3(", "").replace("Color(", "").replace(")", "")
	cleaned = cleaned.replace("[", "").replace("]", "").replace("(", "").replace(")", "")
	cleaned = cleaned.strip_edges()

	var parts: PackedStringArray = cleaned.split(",", false)
	var result: Array = []
	for part in parts:
		var trimmed: String = part.strip_edges()
		if trimmed.is_valid_float():
			result.append(trimmed.to_float())
	return result


# 获取类型名称
func _type_name(p_type: int) -> String:
	match p_type:
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_COLOR: return "Color"
		TYPE_OBJECT: return "Resource/Object"
		_: return "Variant"
