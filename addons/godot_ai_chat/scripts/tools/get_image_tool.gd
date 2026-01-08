@tool
extends AiTool


func _init() -> void:
	name = "get_image_content"
	description = "Reads an image file from the specified path and sends it to the model for analysis. Only supports res:// paths."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the image file, e.g."
			}
		},
		"required": ["path"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path: String = _args.get("path", "")
	
	# [修复] 安全检查：验证文件扩展名
	# 防止读取非图片文件导致对话历史损坏
	var allowed_extensions: Array[String] = ["png", "jpg", "jpeg", "svg"]
	var ext: String = path.get_extension().to_lower()
	if ext not in allowed_extensions:
		return {
			"success": false, 
			"data": "Error: Unsupported file format '%s'. Only image files are supported (png, jpg, jpeg, svg)." % ext
		}
	
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "Error: File does not exist at path " + path}
	
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not file:
		return {"success": false, "data": "Error: Unable to open file " + path}
	
	var buffer = file.get_buffer(file.get_length())
	file.close()
	
	# Determine MIME type based on extension
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
