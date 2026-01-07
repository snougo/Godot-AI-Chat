extends AiTool


func _init() -> void:
	name = "write_notebook"
	description = "Useful for recording **analysis, thoughts, and documentation excerpts**. **STRICTLY PROHIBITED: Do not write code, scripts, or code blocks.** Use this for text-based reasoning only. **DO NOT use for tracking task status** (use todo_list for that)."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"content": {
				"type": "string",
				"description": "The text content to write. Required for 'append' mode. Ignored for 'read'."
			},
			"mode": {
				"type": "string",
				"enum": ["append", "read"],
				"description": "The operation mode. 'append': add new context to end (default); 'read': read `notebook.md` content.",
				"default": "append"
			},
			"path": {
				"type": "string",
				"description": "Required. The full path to the notebook file (e.g. 'res://path/to/workspace/notebook.md')."
			}
		},
		"required": ["mode", "path"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var mode = _args.get("mode", "append")
	var content = _args.get("content", "")
	var target_path = _args.get("path", "")
	
	if target_path.is_empty():
		return {"success": false, "data": "Path is required. Please specify the notebook file path (e.g., res://workspace/notebook.md)."}
	
	# 安全检查：只允许 .md 扩展名
	if target_path.get_extension().to_lower() != "md":
		return {"success": false, "data": "Security Error: Notebook tool only supports .md files."}

	# 确保文件存在，如果不存在则创建（适用于所有模式）
	if not FileAccess.file_exists(target_path):
		var file: FileAccess = FileAccess.open(target_path, FileAccess.WRITE)
		if file:
			file.store_string("# AI Notebook\n")
			file.close()
			ToolBox.refresh_editor_filesystem() # 刷新文件系统以便编辑器能看到新文件
		else:
			return {"success": false, "data": "Failed to create notebook at: " + target_path + " Error: " + str(FileAccess.get_open_error())}
	
	var file: FileAccess
	var result_msg := ""
	
	match mode:
		"read":
			file = FileAccess.open(target_path, FileAccess.READ)
			if file == null:
				return {"success": false, "data": "Failed to open notebook for reading: " + str(FileAccess.get_open_error())}
			var text: String = file.get_as_text()
			file.close()
			return {"success": true, "data": text} # 直接返回内容
		
		"append", _: # Default to append
			file = FileAccess.open(target_path, FileAccess.READ_WRITE)
			if file == null:
				# 尝试以 WRITE 模式重新创建
				file = FileAccess.open(target_path, FileAccess.WRITE)
				if file == null:
					return {"success": false, "data": "Failed to open notebook for appending: " + str(FileAccess.get_open_error())}
			
			file.seek_end()
			# 确保追加前有换行，除非文件是空的
			if file.get_length() > 0:
				file.store_string("\n")
			
			file.store_string(content)
			file.close()
			result_msg = "Content appended to notebook at " + target_path
	
	return {"success": true, "data": result_msg}
