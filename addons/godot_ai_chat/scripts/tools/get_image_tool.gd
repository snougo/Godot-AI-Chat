@tool
extends AiTool

# 允许读取的图片文件扩展名白名单
const ALLOWED_EXTENSIONS = ["png", "jpg", "jpeg"]

func _init() -> void:
	name = "get_image_content"
	description = "Reads an image file from the specified path and sends it to the model for analysis. Only supports res:// paths."


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


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path: String = _args.get("path", "")
	
	# 1. 基础路径安全检查
	if path.is_empty():
		return {"success": false, "data": "Error: 'path' parameter is required."}
	if not path.begins_with("res://"):
		return {"success": false, "data": "Error: Path must start with 'res://'."}
	if ".." in path:
		return {"success": false, "data": "Error: Path traversal ('..') is not allowed."}
	
	# 2. 扩展名白名单检查
	var ext: String = path.get_extension().to_lower()
	if ext not in ALLOWED_EXTENSIONS:
		return {
			"success": false, 
			"data": "Error: Unsupported file format '%s'. Only image files are supported: %s" % [ext, ALLOWED_EXTENSIONS]
		}
	
	# 3. 检查文件是否存在
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "Error: File does not exist at path " + path}
	
	# 4. 读取文件内容
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return {"success": false, "data": "Error: Unable to open file " + path}
	
	var buffer = file.get_buffer(file.get_length())
	file.close()
	
	# 5. 确定 MIME 类型
	var mime := "image/png"
	if path.ends_with(".jpg") or path.ends_with(".jpeg"):
		mime = "image/jpeg"
	elif path.ends_with(".webp"):
		mime = "image/webp"
	elif path.ends_with(".svg"):
		mime = "image/svg+xml"
	
	return {
		"success": true, 
		"data": "Image successfully read and attached to this message.",
		"attachments": {
			"image_data": buffer,
			"mime": mime
		}
	}
