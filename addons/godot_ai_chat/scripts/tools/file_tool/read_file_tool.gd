@tool
extends AiTool

## 读取指定文件的内容（支持场景、脚本、资源、文本、图片元数据等）。
## 不包含文件夹结构读取功能（该功能已移至 manage_folder_tool）。
## 本AI工具功能依赖第三方Godot插件 Context Toolkit


# --- Enums / Constants ---

## 上下文类型与允许的扩展名映射
const EXTENSION_MAP: Dictionary = {
	"scene":      ["tscn", "scn"],
	"script":     ["gd", "gdshader", "glsl"],
	"text":       ["md", "json", "cfg", "txt"],
	"resource":   ["tres", "res"],
	"image_meta": ["png", "jpg", "jpeg"]
}


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "read_file"
	tool_description = "Reads the content of a file."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_type": {
				"type": "string",
				"enum": ["scene", "script", "text", "resource", "image_meta"],
				"description": "The type of file to read."
			},
			"path": {
				"type": "string",
				"description": "The full path to the file."
			}
		},
		"required": ["file_type", "path"]
	}


## 执行文件读取
## [param p_args]: 包含 file_type 和 path 的参数字典
## [return]: 包含成功状态和文件内容的字典
func execute(p_args: Dictionary) -> Dictionary:
	var file_type: String = p_args.get("file_type", "")
	var path: String = p_args.get("path", "")
	
	var context_provider := ContextProvider.new()
	
	if file_type.is_empty() or path.is_empty():
		return {"success": false, "data": "Missing parameters: file_type or path"}
	
	var validation_result: String = _validate_path(path)
	if not validation_result.is_empty():
		return {"success": false, "data": validation_result}
	
	# 安全拦截：禁止读取指定的敏感资源文件
	if file_type == "resource" and (
		path == PluginPaths.PLUGIN_DIR + "plugin_settings_config.tres" or
		path == PluginPaths.PLUGIN_DIR + "sub_agent_config.tres" or
		path == PluginPaths.PLUGIN_DIR + "sketchfab_config.tres"
	):
		return {"success": false, "data": "Error: Due to security reasons, reading this file is prohibited. Please do not attempt again."}
	
	if not EXTENSION_MAP.has(file_type):
		return {"success": false, "data": "Error: Unknown file_type: " + file_type}
	
	var extension_validation: Dictionary = _validate_file_extension(path, file_type)
	if not extension_validation.is_empty():
		return extension_validation
	
	return _read_file_content(file_type, path, context_provider)


# --- Private Functions ---

# 验证路径安全性
# [param p_path]: 要验证的路径
# [return]: 空字符串表示安全，否则返回错误信息
func _validate_path(p_path: String) -> String:
	if not p_path.begins_with("res://"):
		return "Error: Path must start with 'res://'."
	if ".." in p_path:
		return "Error: Path traversal ('..') is not allowed."
	return ""


# 验证文件扩展名是否匹配上下文类型
# [param p_path]: 文件路径
# [param p_file_type]: 上下文类型
# [return]: 空字典表示验证通过，否则返回错误字典
func _validate_file_extension(p_path: String, p_file_type: String) -> Dictionary:
	var allowed_extensions: Array = EXTENSION_MAP[p_file_type]
	var ext: String = p_path.get_extension().to_lower()
	
	if ext not in allowed_extensions:
		return {
			"success": false,
			"data": "Error: Extension '%s' is not allowed for file_type '%s'. Allowed: %s" % [ext, p_file_type, allowed_extensions]
		}
	return {}


# 执行文件内容读取
# [param p_file_type]: 上下文类型
# [param p_path]: 文件路径
# [param p_provider]: 上下文提供者实例
# [return]: 读取结果字典
func _read_file_content(p_file_type: String, p_path: String, p_provider: ContextProvider) -> Dictionary:
	match p_file_type:
		"scene":
			return p_provider.get_scene_tree_as_markdown(p_path)
		"script":
			return p_provider.get_script_content_as_markdown(p_path)
		"text":
			return p_provider.get_text_content_as_markdown(p_path)
		"resource":
			return _read_resource_content(p_path)
		"image_meta":
			return p_provider.get_image_metadata_as_markdown(p_path)
		_:
			return {"success": false, "data": "Internal Error: Unhandled file type."}


# 读取资源文件内容
func _read_resource_content(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	var ext: String = p_path.get_extension().to_lower()
	
	# .tres 是纯文本，沿用原有逻辑
	if ext == "tres":
		var context_provider := ContextProvider.new()
		return context_provider.get_text_content_as_markdown(p_path)
	
	# .res 是二进制，用 load() 取元信息
	var resource: Resource = load(p_path)
	if not resource:
		return {"success": false, "data": "Error: Failed to load resource: " + p_path}
	
	var md: String = "Content for Resource: `%s`\n" % p_path.get_file()
	md += "- **Type**: %s\n" % resource.get_class()
	md += "- **Path**: `%s`\n" % resource.resource_path
	if not resource.resource_name.is_empty():
		md += "- **Name**: %s\n" % resource.resource_name
	
	# 遍历脚本自定义属性
	var has_props := false
	for p in resource.get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			if not has_props:
				md += "\n**Properties:**\n"
				has_props = true
			var val := resource.get(p.name)
			md += "- **%s**: %s\n" % [p.name, _format_property_value(val)]
	
	return {"success": true, "data": md}


# 将属性值转为安全的字符串表示
static func _format_property_value(p_val: Variant) -> String:
	match typeof(p_val):
		TYPE_STRING:
			return "\"%s\"" % p_val
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
			return str(p_val)
		TYPE_ARRAY:
			return "[Array: %d items]" % p_val.size()
		TYPE_DICTIONARY:
			return "[Dictionary: %d keys]" % p_val.size()
		TYPE_OBJECT:
			if p_val is Resource:
				return "[Resource: %s]" % p_val.resource_path.get_file()
			return str(p_val)
		_:
			return str(p_val)
