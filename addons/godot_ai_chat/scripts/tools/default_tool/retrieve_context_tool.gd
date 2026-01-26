@tool
extends AiTool

## 检索当前工作区的上下文信息。
## 支持获取文件夹结构、场景树、脚本文件、文本文件和图片元数据。

# --- Enums / Constants ---

## 上下文类型与允许的扩展名映射
const EXTENSION_MAP: Dictionary = {
	"scene_tree": ["tscn"],
	"script_file": ["gd", "gdshader"],
	"text-based_file": ["txt", "md", "json", "cfg", "tres"],
	"image-meta": ["png", "jpg", "jpeg", "bmp", "tga", "exr"]
}


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "retrieve_context"
	tool_description = "Retrieve context information in current workspace."

# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"context_type": {
				"type": "string",
				"enum": ["folder_structure", "scene_tree", "script_file", "text-based_file", "image-meta"],
				"description": "The type of context to retrieve."
			},
			"path": {
				"type": "string",
				"description": "The full path to the file or directory."
			}
		},
		"required": ["context_type", "path"]
	}


## 执行上下文检索
## [param p_args]: 包含 context_type 和 path 的参数字典
## [return]: 包含成功状态和检索结果的字典
func execute(p_args: Dictionary) -> Dictionary:
	var context_type: String = p_args.get("context_type", "")
	var path: String = p_args.get("path", "")
	
	# ContextProvider为另外一个Godot插件提供的API接口
	var context_provider := ContextProvider.new()
	
	if context_type.is_empty() or path.is_empty():
		return {"success": false, "data": "Missing parameters: context_type or path"}
	
	var validation_result: String = _validate_path(path)
	if not validation_result.is_empty():
		return {"success": false, "data": validation_result}
	
	if context_type == "folder_structure":
		return _handle_folder_structure(path, context_provider)
	
	if not EXTENSION_MAP.has(context_type):
		return {"success": false, "data": "Error: Unknown context_type: " + context_type}
	
	var extension_validation: Dictionary = _validate_file_extension(path, context_type)
	if not extension_validation.is_empty():
		return extension_validation
	
	return _execute_context_retrieval(context_type, path, context_provider)


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


## 处理文件夹结构检索
## [param p_path]: 文件夹路径
## [param p_provider]: 上下文提供者实例
## [return]: 检索结果字典
func _handle_folder_structure(p_path: String, p_provider: ContextProvider) -> Dictionary:
	var dir = DirAccess.open("res://")
	if not dir.dir_exists(p_path):
		return {"success": false, "data": "Error: Directory not found: " + p_path}
	return p_provider.get_folder_structure_as_markdown(p_path)


## 执行具体的上下文检索
## [param p_context_type]: 上下文类型
## [param p_path]: 文件路径
## [param p_provider]: 上下文提供者实例
## [return]: 检索结果字典
func _execute_context_retrieval(p_context_type: String, p_path: String, p_provider: ContextProvider) -> Dictionary:
	match p_context_type:
		"scene_tree":
			return p_provider.get_scene_tree_as_markdown(p_path)
		"script_file":
			return p_provider.get_script_content_as_markdown(p_path)
		"text-based_file":
			return p_provider.get_text_content_as_markdown(p_path)
		"image-meta":
			return p_provider.get_image_metadata_as_markdown(p_path)
		_:
			return {"success": false, "data": "Internal Error: Unhandled context type."}
