@tool
extends AiTool

## 资源文件属性获取工具。
## 加载 .tres/.res 资源文件，列出其所有可编辑属性及当前值。
## 与 edit_resource_tool 配合使用：先查属性列表，再修改属性。


# --- Enums / Constants ---

const RESOURCE_EXTENSIONS: Array[String] = ["tres", "res"]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "get_resource_properties"
	tool_description = "Lists all editable properties of a Resource (.tres/.res) file with their current values and types."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Full path to the .tres or .res file (e.g., 'res://materials/stone.tres')."
			}
		},
		"required": ["path"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var file_path: String = p_args.get("path", "").strip_edges()
	if file_path.is_empty():
		return {"success": false, "data": "Error: 'path' is required."}

	# 安全校验
	var safety_err: String = validate_path_safety(file_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}

	if not FileAccess.file_exists(file_path):
		return {"success": false, "data": "Error: File not found at %s." % file_path}

	var ext: String = file_path.get_extension().to_lower()
	if ext not in RESOURCE_EXTENSIONS:
		return {"success": false, "data": "Error: Invalid extension '.%s'. Resource files must use: .tres or .res." % ext}

	# 加载资源
	var resource: Resource = load(file_path)
	if not resource:
		return {"success": false, "data": "Error: Failed to load resource from %s." % file_path}

	# 收集属性
	var properties: Array[Dictionary] = []
	for prop in resource.get_property_list():
		var usage: int = prop.get("usage", 0)

		# 只保留编辑器可见属性
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		# 过滤组/类别等非实际属性条目
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_SUBGROUP):
			continue

		var prop_name: String = prop.get("name", "")
		var prop_type: int = prop.get("type", TYPE_NIL)
		var prop_hint: int = prop.get("hint", 0)
		var hint_string: String = prop.get("hint_string", "")

		# 获取当前值
		var current_value: Variant = resource.get(prop_name)

		properties.append({
			"name": prop_name,
			"value": _format_value(current_value),
			"type": type_string(prop_type),
			"hint": hint_string if not hint_string.is_empty() else ""
		})

	if properties.is_empty():
		return {"success": true, "data": "No editable properties found for this resource."}

	# 格式化输出
	var lines: PackedStringArray = []
	lines.append("**📦 Resource:** %s" % file_path)
	lines.append("**🏷️ Type:** %s" % resource.get_class())
	if "resource_name" in resource and not resource.resource_name.is_empty():
		lines.append("**📛 Name:** %s" % resource.resource_name)
	lines.append("")
	lines.append("| Property | Current Value | Type | Hint |")
	lines.append("|----------|--------------|------|------|")

	for p in properties:
		var name: String = p["name"]
		var value: String = (p["value"] as String).replace("|", "\\|")
		var type_name: String = p["type"]
		var hint: String = p["hint"]
		# 截断过长的值避免表格混乱
		if value.length() > 80:
			value = value.left(77) + "..."
		lines.append("| %s | %s | %s | %s |" % [name, value, type_name, hint])

	lines.append("")
	lines.append("💡 Use `edit_resource` to modify these properties.")

	return {"success": true, "data": "\n".join(lines)}


# --- Private Functions ---

## 将属性值格式化为字符串
func _format_value(p_value: Variant) -> String:
	if p_value == null:
		return "null"

	var t := typeof(p_value)
	match t:
		TYPE_OBJECT:
			if p_value is Resource:
				var path: String = p_value.resource_path
				if not path.is_empty():
					return path
				return "[%s: %s]" % [p_value.get_class(), p_value.resource_name if "resource_name" in p_value else "unnamed"]
			return str(p_value)
		TYPE_ARRAY:
			return str(p_value)
		TYPE_DICTIONARY:
			return str(p_value)
		TYPE_STRING:
			var s: String = p_value as String
			if s.length() > 100:
				s = s.left(97) + "..."
			return "\"" + s + "\""
		_:
			return str(p_value)
