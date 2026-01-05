@tool
extends AiTool


func _init() -> void:
	name = "get_image_content"
	description = "读取指定路径的图片文件并将其发送给模型进行分析。支持 res:// 路径。"


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "图片的完整路径，例如 'res://assets/sprite.png'"
			}
		},
		"required": ["path"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path: String = _args.get("path", "")
	
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "错误：文件不存在于路径 " + path}
	
	var file = FileAccess.open(path, FileAccess.READ)
	if not file:
		return {"success": false, "data": "错误：无法打开文件 " + path}
	
	var buffer = file.get_buffer(file.get_length())
	file.close()
	
	# 根据后缀名判断 MIME
	var mime = "image/png"
	if path.ends_with(".jpg") or path.ends_with(".jpeg"):
		mime = "image/jpeg"
	elif path.ends_with(".webp"):
		mime = "image/webp"
	elif path.ends_with(".svg"):
		mime = "image/svg+xml"
	
	return {
		"success": true, 
		"data": "图片已成功读取并附加到此消息中。", # 返回给 AI 的文本描述
		"attachments": { # 特殊字段，用于工作流管理器识别
			"image_data": buffer,
			"mime": mime
		}
	}
