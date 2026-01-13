@tool
extends AiTool


func _init() -> void:
	tool_name = "notebook"
	tool_description = "Record plain-text task details or temporary document excerpts."


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
				"description": "The operation mode. 'append': add new context to end (default); 'read': read `Notebook.md` content.",
				"default": "append"
			},
			"path": {
				"type": "string",
				"description": "Required. The full path to the current workspace `Notebook.md` file (e.g. 'res://current_workspace_path/Notebook.md')."
			}
		},
		"required": ["mode", "path"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var mode = _args.get("mode", "append")
	var content = _args.get("content", "")
	var target_path = _args.get("path", "")
	
	# 1. 基础参数检查
	if target_path.is_empty():
		return {"success": false, "data": "Error: Path is required. Please specify the notebook file path (e.g., res://current_workspace_path/Notebook.md)."}
	
	# 2. 安全性检查
	if not target_path.begins_with("res://"):
		return {"success": false, "data": "Error: Path must start with 'res://'."}
	if ".." in target_path:
		return {"success": false, "data": "Error: Path traversal ('..') is not allowed."}
	if target_path.get_extension().to_lower() != "md":
		return {"success": false, "data": "Security Error: Notebook tool only supports .md files."}
	
	# 3. 确保文件存在，如果不存在则创建（适用于所有模式）
	if not FileAccess.file_exists(target_path):
		# 确保目录存在
		var base_dir = target_path.get_base_dir()
		if not DirAccess.dir_exists_absolute(base_dir):
			return {"success": false, "data": "Error: Directory does not exist: " + base_dir}
		
		var file: FileAccess = FileAccess.open(target_path, FileAccess.WRITE)
		if file:
			file.store_string("# AI Notebook\n")
			file.close()
			#ToolBox.update_editor_filesystem(target_path)
			ToolBox.refresh_editor_filesystem()
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
			
			# 插入分隔符：换行 + 分割线 + 两个换行
			# 只有当文件不为空时才添加分隔符，避免文件开头出现分割线
			if file.get_length() > 0:
				file.store_string("\n---\n\n")
			
			file.store_string(content)
			file.close()
			ToolBox.update_editor_filesystem(target_path)
			#ToolBox.refresh_editor_filesystem()
			result_msg = "Content appended to notebook at " + target_path
	
	return {"success": true, "data": result_msg}
