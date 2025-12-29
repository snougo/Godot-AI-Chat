extends AiTool


# 硬编码路径，确保安全性
const NOTEBOOK_PATH = "res://addons/godot_ai_chat/notebook.md"

func _init() -> void:
	name = "write_notebook"
	description = "Write content to the 'notebook.md' file. Useful for keeping notes, plans, or code snippets during long tasks. Supports appending, overwriting, or clearing the file."

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"content": {
				"type": "string",
				"description": "The text content to write. Required for 'append' and 'overwrite' modes."
			},
			"mode": {
				"type": "string",
				"enum": ["append", "overwrite", "clear"],
				"description": "The operation mode. 'append': add to end (default); 'overwrite': replace entire file; 'clear': empty the file.",
				"default": "append"
			}
		},
		"required": ["mode"]
	}

func execute(args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var mode = args.get("mode", "append")
	var content = args.get("content", "")
	
	# 确保文件存在，如果不存在则创建
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
			result_msg = "Notebook cleared."
		
		"overwrite":
			file = FileAccess.open(NOTEBOOK_PATH, FileAccess.WRITE)
			if file == null:
				return {"success": false, "data": "Failed to open notebook for overwriting: " + str(FileAccess.get_open_error())}
			file.store_string(content)
			result_msg = "Notebook overwritten."
		
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
			result_msg = "Content appended to notebook."
	
	file.close()
	
	return {"success": true, "data": result_msg}
