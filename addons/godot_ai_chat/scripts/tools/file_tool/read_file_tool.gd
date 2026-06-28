@tool
extends AiTool

## 读取指定文件的内容（支持场景、脚本、资源、文本、图片元数据等）。
## 文件类型根据扩展名自动推断，无需手动指定。
## 不包含文件夹结构读取功能（该功能已移至 manage_folder_tool）。


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
	tool_description = "Reads a file."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the file."
			}
		},
		"required": ["path"]
	}


## 执行文件读取
## [param p_args]: 包含 path 的参数字典
## [return]: 包含成功状态和文件内容的字典
func execute(p_args: Dictionary) -> ToolResult:
	var path: String = p_args.get("path", "")
	
	if path.is_empty():
		return ToolResult.fail("Missing parameter: path")
	
	var validation_result: String = _validate_path(path)
	if not validation_result.is_empty():
		return ToolResult.fail(validation_result)
	
	# 自动检测文件类型
	var file_type: String = _auto_detect_file_type(path)
	if file_type.is_empty():
		var supported := ""
		for ft in EXTENSION_MAP.keys():
			supported += ft + ": [" + ", ".join(EXTENSION_MAP[ft]) + "]\n"
		return ToolResult.fail("Error: Could not auto-detect file type. Unsupported extension.\nSupported types:\n" + supported)
	
	# 安全拦截：禁止读取指定的敏感资源文件
	if file_type == "resource" and (
		path == PluginPaths.PLUGIN_DIR + "plugin_settings_config.tres" or
		path == PluginPaths.PLUGIN_DIR + "sub_agent_config.tres" or
		path == PluginPaths.PLUGIN_DIR + "sketchfab_config.tres"
	):
		return ToolResult.fail("Error: Due to security reasons, reading this file is prohibited. Please do not attempt again.")
	
	return _read_file_content(file_type, path)


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


# 根据文件扩展名自动推断文件类型
# [param p_path]: 文件路径
# [return]: 推断出的文件类型字符串，如果无法识别则返回空字符串
static func _auto_detect_file_type(p_path: String) -> String:
	var ext: String = p_path.get_extension().to_lower()
	for file_type in EXTENSION_MAP:
		if ext in EXTENSION_MAP[file_type]:
			return file_type
	return ""


# 执行文件内容读取
# [param p_file_type]: 上下文类型
# [param p_path]: 文件路径
# [return]: 读取结果字典
func _read_file_content(p_file_type: String, p_path: String) -> ToolResult:
	if not FileAccess.file_exists(p_path):
		return ToolResult.fail("Error: File not found: " + p_path)
	
	match p_file_type:
		"scene":
			return _wrap_reader_result(FileContentReader.read_scene_content(p_path))
		"script":
			return _wrap_reader_result(FileContentReader.read_script_content(p_path))
		"text":
			return _wrap_reader_result(FileContentReader.read_text_content(p_path))
		"resource":
			return _wrap_reader_result(FileContentReader.read_resource_content(p_path))
		"image_meta":
			return _wrap_reader_result(FileContentReader.read_image_metadata(p_path))
		_:
			return ToolResult.fail("File Type Error: Unsupport file type.")


func _wrap_reader_result(p_dict: Dictionary) -> ToolResult:
	var img_data: PackedByteArray = p_dict.get("image_data", PackedByteArray())
	if not img_data.is_empty():
		return ToolResult.ok_with_image(p_dict.get("data", ""), img_data, p_dict.get("mime", "image/png"))
	elif p_dict.get("success", false):
		return ToolResult.ok(p_dict.get("data", ""))
	else:
		return ToolResult.fail(p_dict.get("data", "Unknown error"))
