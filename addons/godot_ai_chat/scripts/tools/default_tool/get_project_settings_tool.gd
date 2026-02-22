@tool
extends AiTool

## 读取 Godot 项目设置的详细信息。
## 支持两种查询模式：按精确路径查询单个设置，或按类别批量查询。


# --- Constants ---

## 查询模式常量
const MODE_BY_PATH := "by_path"
const MODE_BY_CATEGORY := "by_category"

## 显示限制常量
const MAX_DISPLAY_SETTINGS := 50
const MAX_VALUE_DISPLAY_LENGTH := 50
const MAX_COLLECTION_VALUE_LENGTH := 100

## 相似设置建议的最大数量
const MAX_SIMILAR_SUGGESTIONS := 3

## 常见的设置类别
const COMMON_CATEGORIES: Array[String] = [
	"application",
	"audio",
	"autoload",
	"debug",
	"display",
	"dotnet",
	"editor",
	"gui",
	"input",
	"internationalization",
	"layer_names",
	"logging",
	"memory",
	"navigation",
	"network",
	"physics",
	"rendering",
	"shader_globals",
	"threading",
	"xr"
]


# --- Variables ---

## 设置缓存
var _settings_cache: Array[Dictionary] = []

## 缓存是否有效
var _cache_valid: bool = false


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "get_project_settings"
	tool_description = "Retrieves detailed Godot Project Settings. Supports two query modes: by specific path or by category."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"mode": {
				"type": "string",
				"enum": [MODE_BY_PATH, MODE_BY_CATEGORY],
				"description": "Query mode: 'by_path' for single setting, 'by_category' for all settings in a category."
			},
			"setting_path": {
				"type": "string",
				"description": "Required when mode='by_path'. Full setting path (e.g., 'display/window/size/viewport_width')."
			},
			"category": {
				"type": "string",
				"enum": COMMON_CATEGORIES,
				"description": "Required when mode='by_category'. Setting category to query (e.g., 'display', 'input')."
			}
		},
		"required": ["mode"],
		"allOf": [
			{
				"if": {
					"properties": {"mode": {"const": MODE_BY_PATH}}
				},
				"then": {
					"required": ["setting_path"]
				}
			},
			{
				"if": {
					"properties": {"mode": {"const": MODE_BY_CATEGORY}}
				},
				"then": {
					"required": ["category"]
				}
			}
		]
	}


## 执行项目设置查询
func execute(p_args: Dictionary) -> Dictionary:
	assert(p_args is Dictionary, "p_args must be a Dictionary")
	
	var mode: String = p_args.get("mode", "")
	assert(mode is String, "mode must be a String")
	
	match mode:
		MODE_BY_PATH:
			var setting_path: String = p_args.get("setting_path", "")
			assert(setting_path is String, "setting_path must be a String")
			
			if setting_path.is_empty():
				return {"success": false, "data": "Error: 'setting_path' is required when mode='by_path'"}
			return _query_by_path(setting_path)
		
		MODE_BY_CATEGORY:
			var category: String = p_args.get("category", "")
			assert(category is String, "category must be a String")
			
			if category.is_empty():
				return {"success": false, "data": "Error: 'category' is required when mode='by_category'"}
			return _query_by_category(category)
		
		_:
			return {"success": false, "data": "Error: Invalid mode. Use 'by_path' or 'by_category'"}


# --- Private Functions ---

## 按精确路径查询单个设置
func _query_by_path(p_path: String) -> Dictionary:
	assert(p_path is String, "p_path must be a String")
	assert(not p_path.is_empty(), "p_path cannot be empty")
	
	if not ProjectSettings.has_setting(p_path):
		var suggestions: Array[String] = _find_similar_settings(p_path)
		var error_msg: String = "Setting not found: `%s`." % p_path
		
		if not suggestions.is_empty():
			error_msg += "\n\n**Did you mean:**\n"
			for suggestion: String in suggestions:
				error_msg += "- `%s`\n" % suggestion
		else:
			error_msg += "\n\n**Available categories:** %s" % [COMMON_CATEGORIES]
		
		return {"success": false, "data": error_msg}
	
	var value: Variant = ProjectSettings.get_setting(p_path)
	var value_str: String = _format_value(value)
	var is_default: bool = not _is_setting_changed(p_path)
	
	var result: String = """### Project Setting: `%s`

| Property | Value |
|----------|-------|
| **Path** | `%s` |
| **Value** | %s |
| **Type** | %s |
| **Status** | %s |
""" % [p_path, p_path, value_str, _get_type_name(typeof(value)), "🟢 Default" if is_default else "🔴 Modified"]
	
	return {"success": true, "data": result}


## 按类别查询设置
func _query_by_category(p_category: String) -> Dictionary:
	assert(p_category is String, "p_category must be a String")
	assert(not p_category.is_empty(), "p_category cannot be empty")
	
	var settings: Array[Dictionary] = _collect_settings()
	var filtered_settings: Array[Dictionary] = []
	
	for setting: Dictionary in settings:
		var path: String = setting.get("path", "")
		if path.begins_with(p_category + "/"):
			filtered_settings.append(setting)
	
	if filtered_settings.is_empty():
		return {
			"success": false,
			"data": "No settings found in category: '%s'. Available categories: %s" % [p_category, COMMON_CATEGORIES]
		}
	
	return _format_settings_table(filtered_settings, "Category: " + p_category)


## 收集设置列表（带缓存）
func _collect_settings() -> Array[Dictionary]:
	# 如果缓存有效，直接返回
	if _cache_valid and not _settings_cache.is_empty():
		return _settings_cache
	
	# 清空缓存
	_settings_cache.clear()
	
	# 收集所有设置
	var properties: Array[Dictionary] = ProjectSettings.get_property_list()
	
	for prop: Dictionary in properties:
		var name: String = prop.get("name", "")
		if "/" in name and not name.begins_with("_"):
			_settings_cache.append(_get_setting_info(name))
	
	# 标记缓存有效
	_cache_valid = true
	
	return _settings_cache


## 获取单个设置的详细信息
func _get_setting_info(p_path: String) -> Dictionary:
	assert(p_path is String, "p_path must be a String")
	assert(not p_path.is_empty(), "p_path cannot be empty")
	
	var value: Variant = ProjectSettings.get_setting(p_path)
	return {
		"path": p_path,
		"value": _format_value(value),
		"type": _get_type_name(typeof(value)),
		"changed": _is_setting_changed(p_path)
	}


## 检查设置是否被修改
func _is_setting_changed(p_path: String) -> bool:
	assert(p_path is String, "p_path must be a String")
	
	var changed: PackedStringArray = ProjectSettings.get_changed_settings()
	return p_path in changed


## 查找相似的设置路径
func _find_similar_settings(p_path: String) -> Array[String]:
	assert(p_path is String, "p_path must be a String")
	
	var all_settings: Array[Dictionary] = _collect_settings()
	var similar: Array[Array] = []  # [distance, path]
	
	for setting: Dictionary in all_settings:
		var path: String = setting.get("path", "")
		var distance: int = _levenshtein_distance(p_path.to_lower(), path.to_lower())
		
		# 只保留距离较近的设置
		if distance < 10:
			similar.append([distance, path])
	
	# 按距离排序
	similar.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	
	# 提取结果
	var result: Array[String] = []
	for i: int in range(min(similar.size(), MAX_SIMILAR_SUGGESTIONS)):
		result.append(similar[i][1])
	
	return result


## 计算 Levenshtein 距离（编辑距离）
func _levenshtein_distance(p_s1: String, p_s2: String) -> int:
	assert(p_s1 is String, "p_s1 must be a String")
	assert(p_s2 is String, "p_s2 must be a String")
	
	var m: int = p_s1.length()
	var n: int = p_s2.length()
	
	# 边界情况
	if m == 0:
		return n
	if n == 0:
		return m
	
	# 创建 DP 表
	var dp: Array[Array] = []
	for i: int in range(m + 1):
		var row: Array[int] = []
		for j: int in range(n + 1):
			row.append(0)
		dp.append(row)
	
	# 初始化
	for i: int in range(m + 1):
		dp[i][0] = i
	for j: int in range(n + 1):
		dp[0][j] = j
	
	# 填充 DP 表
	for i: int in range(1, m + 1):
		for j: int in range(1, n + 1):
			var cost: int = 0 if p_s1[i - 1] == p_s2[j - 1] else 1
			dp[i][j] = min(
				min(dp[i - 1][j] + 1, dp[i][j - 1] + 1),
				dp[i - 1][j - 1] + cost
			)
	
	return dp[m][n]


## 格式化值为字符串
func _format_value(p_value: Variant) -> String:
	# 处理 null
	if p_value == null:
		return "null"
	
	# 处理对象类型（防止循环引用）
	if typeof(p_value) == TYPE_OBJECT:
		var obj: Object = p_value
		if obj is Resource:
			var res: Resource = obj
			return "Resource(`%s`)" % (res.resource_path if res.resource_path else "unknown")
		return "Object(%s)" % obj.get_class()
	
	# 处理不同类型
	var formatted: String = ""
	
	match typeof(p_value):
		TYPE_STRING:
			var s: String = p_value
			if s.is_empty():
				formatted = '""'
			else:
				formatted = '"%s"' % s
		TYPE_COLOR:
			var c: Color = p_value
			formatted = "Color(%.2f, %.2f, %.2f, %.2f)" % [c.r, c.g, c.b, c.a]
		TYPE_VECTOR2:
			var v: Vector2 = p_value
			formatted = "Vector2(%.2f, %.2f)" % [v.x, v.y]
		TYPE_VECTOR2I:
			var vi: Vector2i = p_value
			formatted = "Vector2i(%d, %d)" % [vi.x, vi.y]
		TYPE_VECTOR3:
			var v3: Vector3 = p_value
			formatted = "Vector3(%.2f, %.2f, %.2f)" % [v3.x, v3.y, v3.z]
		TYPE_VECTOR3I:
			var v3i: Vector3i = p_value
			formatted = "Vector3i(%d, %d, %d)" % [v3i.x, v3i.y, v3i.z]
		TYPE_ARRAY, TYPE_PACKED_STRING_ARRAY:
			var arr: Array = p_value
			if arr.is_empty():
				formatted = "[]"
			else:
				formatted = str(arr)
		TYPE_DICTIONARY:
			var dict: Dictionary = p_value
			if dict.is_empty():
				formatted = "{}"
			else:
				formatted = str(dict)
		_:
			formatted = str(p_value)
	
	# 防止超大值
	if formatted.length() > MAX_COLLECTION_VALUE_LENGTH:
		formatted = formatted.substr(0, MAX_COLLECTION_VALUE_LENGTH) + "... (truncated)"
	
	return formatted


## 获取类型名称
func _get_type_name(p_type: int) -> String:
	assert(p_type is int, "p_type must be an int")
	
	match p_type:
		TYPE_NIL: return "Nil"
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_RECT2: return "Rect2"
		TYPE_RECT2I: return "Rect2i"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_TRANSFORM2D: return "Transform2D"
		TYPE_VECTOR4: return "Vector4"
		TYPE_VECTOR4I: return "Vector4i"
		TYPE_PLANE: return "Plane"
		TYPE_QUATERNION: return "Quaternion"
		TYPE_AABB: return "AABB"
		TYPE_BASIS: return "Basis"
		TYPE_TRANSFORM3D: return "Transform3D"
		TYPE_PROJECTION: return "Projection"
		TYPE_COLOR: return "Color"
		TYPE_STRING_NAME: return "StringName"
		TYPE_NODE_PATH: return "NodePath"
		TYPE_RID: return "RID"
		TYPE_OBJECT: return "Object"
		TYPE_CALLABLE: return "Callable"
		TYPE_SIGNAL: return "Signal"
		TYPE_DICTIONARY: return "Dictionary"
		TYPE_ARRAY: return "Array"
		TYPE_PACKED_BYTE_ARRAY: return "PackedByteArray"
		TYPE_PACKED_INT32_ARRAY: return "PackedInt32Array"
		TYPE_PACKED_INT64_ARRAY: return "PackedInt64Array"
		TYPE_PACKED_FLOAT32_ARRAY: return "PackedFloat32Array"
		TYPE_PACKED_FLOAT64_ARRAY: return "PackedFloat64Array"
		TYPE_PACKED_STRING_ARRAY: return "PackedStringArray"
		TYPE_PACKED_VECTOR2_ARRAY: return "PackedVector2Array"
		TYPE_PACKED_VECTOR3_ARRAY: return "PackedVector3Array"
		TYPE_PACKED_COLOR_ARRAY: return "PackedColorArray"
		_: return "Unknown"


## 格式化设置为 Markdown 表格
func _format_settings_table(p_settings: Array[Dictionary], p_title: String) -> Dictionary:
	assert(p_settings is Array, "p_settings must be an Array")
	assert(p_title is String, "p_title must be a String")
	
	if p_settings.is_empty():
		return {"success": true, "data": "No settings to display."}
	
	var md: String = "### %s\n\n" % p_title
	md += "| Setting Path | Value | Type | Status |\n"
	md += "|-------------|-------|------|--------|\n"
	
	var displayed: int = 0
	
	for setting: Dictionary in p_settings:
		var path: String = setting.get("path", "")
		var value: String = setting.get("value", "")
		var type: String = setting.get("type", "")
		var changed: bool = setting.get("changed", false)
		
		# 截断过长的值
		if value.length() > MAX_VALUE_DISPLAY_LENGTH:
			value = value.substr(0, MAX_VALUE_DISPLAY_LENGTH - 3) + "..."
		
		# 转义 Markdown 特殊字符
		value = value.replace("|", "\\|")
		
		# 高亮修改过的设置
		var status: String = "🟢 Default" if not changed else "🔴 Modified"
		var path_display: String = "**`%s`**" % path if changed else "`%s`" % path
		
		md += "| %s | %s | %s | %s |\n" % [path_display, value, type, status]
		displayed += 1
		
		if displayed >= MAX_DISPLAY_SETTINGS:
			md += "\n*... and %d more settings* \n" % (p_settings.size() - MAX_DISPLAY_SETTINGS)
			break
	
	md += "\n\n**Total:** %d settings" % p_settings.size()
	
	return {"success": true, "data": md}


## 清除缓存（供外部调用）
func clear_cache() -> void:
	_settings_cache.clear()
	_cache_valid = false
