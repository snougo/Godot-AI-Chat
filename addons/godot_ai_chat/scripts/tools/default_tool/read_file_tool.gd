@tool
extends AiTool

## 读取指定文件的内容（支持场景、脚本、资源、文本、图片元数据等）。
## 不包含文件夹结构读取功能（该功能已移至 manage_folder_tool）。
## 本AI工具功能依赖第三方Godot插件 Context Toolkit


# --- Enums / Constants ---

## 上下文类型与允许的扩展名映射
const EXTENSION_MAP: Dictionary = {
	"scene":      ["tscn"],
	"gdscript":   ["gd"],
	"shader":     ["gdshader", "glsl"],
	"resource":   ["tres"],
	"markdown":   ["md"],
	"config":     ["json", "cfg"],
	"plain_text": ["txt"],
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
			"context_type": {
				"type": "string",
				"enum": ["scene", "gdscript", "shader", "resource", "markdown", "config", "plain_text", "image_meta"],
				"description": "The type of file to read."
			},
			"path": {
				"type": "string",
				"description": "The full path to the file."
			}
		},
		"required": ["context_type", "path"]
	}


## 执行文件读取
## [param p_args]: 包含 context_type 和 path 的参数字典
## [return]: 包含成功状态和文件内容的字典
func execute(p_args: Dictionary) -> Dictionary:
	var context_type: String = p_args.get("context_type", "")
	var path: String = p_args.get("path", "")
	
	var context_provider := ContextProvider.new()
	
	if context_type.is_empty() or path.is_empty():
		return {"success": false, "data": "Missing parameters: context_type or path"}
	
	var validation_result: String = _validate_path(path)
	if not validation_result.is_empty():
		return {"success": false, "data": validation_result}
	
	# 安全拦截：禁止读取本插件目录下的资源文件，防止API密钥等敏感信息泄漏
	#if context_type == "resource" and path.begins_with(PluginPaths.PLUGIN_DIR):
		#return {"success": false, "data": "Error: Due to security reasons, reading this file is prohibited. Please do not attempt again."}
	
	# 安全拦截：禁止读取指定的敏感资源文件
	if context_type == "resource" and (
		path == PluginPaths.PLUGIN_DIR + "plugin_settings_config.tres" or
		path == PluginPaths.PLUGIN_DIR + "sub_agent_config.tres"
	):
		return {"success": false, "data": "Error: Due to security reasons, reading this file is prohibited. Please do not attempt again."}
	
	if not EXTENSION_MAP.has(context_type):
		return {"success": false, "data": "Error: Unknown context_type: " + context_type}
	
	var extension_validation: Dictionary = _validate_file_extension(path, context_type)
	if not extension_validation.is_empty():
		return extension_validation
	
	return _read_file_content(context_type, path, context_provider)


# --- Private Functions ---

## 验证路径安全性
## [param p_path]: 要验证的路径
## [return]: 空字符串表示安全，否则返回错误信息
func _validate_path(p_path: String) -> String:
	if not p_path.begins_with("res://"):
		return "Error: Path must start with 'res://'."
	if ".." in p_path:
		return "Error: Path traversal ('..') is not allowed."
	return ""


## 验证文件扩展名是否匹配上下文类型
## [param p_path]: 文件路径
## [param p_context_type]: 上下文类型
## [return]: 空字典表示验证通过，否则返回错误字典
func _validate_file_extension(p_path: String, p_context_type: String) -> Dictionary:
	var allowed_extensions: Array = EXTENSION_MAP[p_context_type]
	var ext: String = p_path.get_extension().to_lower()
	
	if ext not in allowed_extensions:
		return {
			"success": false,
			"data": "Error: Extension '%s' is not allowed for context_type '%s'. Allowed: %s" % [ext, p_context_type, allowed_extensions]
		}
	return {}


## 执行文件内容读取
## [param p_context_type]: 上下文类型
## [param p_path]: 文件路径
## [param p_provider]: 上下文提供者实例
## [return]: 读取结果字典
func _read_file_content(p_context_type: String, p_path: String, p_provider: ContextProvider) -> Dictionary:
	match p_context_type:
		"scene":
			return p_provider.get_scene_tree_as_markdown(p_path)
		"gdscript", "shader":
			return p_provider.get_script_content_as_markdown(p_path)
		"resource", "markdown", "config", "plain_text":
			return p_provider.get_text_content_as_markdown(p_path)
		"image_meta":
			return p_provider.get_image_metadata_as_markdown(p_path)
		_:
			return {"success": false, "data": "Internal Error: Unhandled context type."}
