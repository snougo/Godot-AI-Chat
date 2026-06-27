@tool
extends AiTool

## 从指定路径读取图片文件。
## 支持读取图片数据并附加到消息中。


# --- Enums / Constants ---

## 允许读取的图片文件扩展名白名单
const ALLOWED_EXTENSIONS: Array[String] = ["png", "jpg", "jpeg"]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "view_image"
	tool_description = "Reads an image file from the specified path."
	security_level = SecurityLevel.READ_ONLY


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the image file."
			}
		},
		"required": ["path"]
	}


## 执行图片读取操作
func execute(p_args: Dictionary) -> ToolResult:
	var path: String = p_args.get("path", "")
	
	if path.is_empty():
		return ToolResult.fail("Error: 'path' parameter is required.")
	
	var validation_result: Dictionary = _validate_path(path)
	if not validation_result.get("success", false):
		return ToolResult.fail(validation_result.data)
	
	var extension_check: Dictionary = _validate_extension(path)
	if not extension_check.get("success", false):
		return ToolResult.fail(extension_check.data)
	
	return _read_image_file(path)

# --- Private Functions ---

## 验证路径安全性
func _validate_path(p_path: String) -> Dictionary:
	if not p_path.begins_with("res://"):
		return {"success": false, "data": "Error: Path must start with 'res://'."}
	if ".." in p_path:
		return {"success": false, "data": "Error: Path traversal ('..') is not allowed."}
	return {"success": true}


## 验证文件扩展名
func _validate_extension(p_path: String) -> Dictionary:
	var ext: String = p_path.get_extension().to_lower()
	if ext not in ALLOWED_EXTENSIONS:
		return {
			"success": false,
			"data": "Error: Unsupported file format '%s'. Only these image extensions are supported: %s" % [ext, ALLOWED_EXTENSIONS]
		}
	return {"success": true}


## 读取图片文件
func _read_image_file(p_path: String) -> ToolResult:
	if not FileAccess.file_exists(p_path):
		return ToolResult.fail("Error: File does not exist at path " + p_path)
	
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not file:
		return ToolResult.fail("Error: Unable to open file " + p_path)
	
	var buffer: PackedByteArray = file.get_buffer(file.get_length())
	file.close()
	
	var mime: String = _determine_mime_type(p_path)
	
	return ToolResult.ok_with_image(
		"Image successfully read and attached to this message.",
		buffer,
		mime
	)


## 根据文件扩展名确定 MIME 类型
func _determine_mime_type(p_path: String) -> String:
	if p_path.ends_with(".jpg") or p_path.ends_with(".jpeg"):
		return "image/jpeg"
	return "image/png"
