extends AiTool


# 硬编码路径，确保安全性
const NOTEBOOK_PATH = "res://addons/godot_ai_chat/notebook.md"


func _init() -> void:
	name = "write_notebook"
	# 修改描述，反映新的功能
	description = "Useful for recording **long-form notes, analysis, and architecture designs**. Use this for unstructured thinking or saving context. **DO NOT use for tracking task status** (use todo_list for that)."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"content": {
				"type": "string",
				"description": "The text content to write. Required for 'append' mode. Ignored for 'read' and 'clear'."
			},
			"mode": {
				"type": "string",
				"enum": ["append", "clear", "read"],
				"description": "The operation mode. 'append': add to end (default); 'read': read file content; 'clear': empty the file.",
				"default": "append"
			}
		},
		"required": ["mode"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var mode = _args.get("mode", "append")
	var content = _args.get("content", "")
	
	# 确保文件存在，如果不存在则创建（对于 read 模式也很有用，防止报错）
	if not FileAccess.file_exists(NOTEBOOK_PATH):
		var file = FileAccess.open(NOTEBOOK_PATH, FileAccess.WRITE)
		if file:
			file.store_string("# AI Notebook\n")
			file.close()
	
	var file: FileAccess
	var result_msg = ""
	
	match mode:
		"clear":
			file = FileAccess.open(NOTEBOOK_PATH, FileAccess.WRITE)
			if file == null:
				return {"success": false, "data": "Failed to open notebook for clearing: " + str(FileAccess.get_open_error())}
			# 打开即清空
			file.close()
			result_msg = "Notebook cleared."
		
		"read":
			file = FileAccess.open(NOTEBOOK_PATH, FileAccess.READ)
			if file == null:
				return {"success": false, "data": "Failed to open notebook for reading: " + str(FileAccess.get_open_error())}
			var text = file.get_as_text()
			file.close()
			return {"success": true, "data": text} # 直接返回内容
		
		"append", _: # Default to append
			file = FileAccess.open(NOTEBOOK_PATH, FileAccess.READ_WRITE)
			if file == null:
				# 尝试以 WRITE 模式创建
				file = FileAccess.open(NOTEBOOK_PATH, FileAccess.WRITE)
				if file == null:
					return {"success": false, "data": "Failed to open notebook for appending: " + str(FileAccess.get_open_error())}
			
			file.seek_end()
			# 确保追加前有换行，除非文件是空的
			if file.get_length() > 0:
				file.store_string("\n")
			
			file.store_string(content)
			file.close()
			result_msg = "Content appended to notebook."
	
	return {"success": true, "data": result_msg}
