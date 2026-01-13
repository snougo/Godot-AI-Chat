@tool
extends AiTool


func _init() -> void:
	tool_name = "todo_list"
	tool_description = "Manage tasks in the current workspace `TODO.md` file by adding, completing, or listing task items and execution steps."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["add", "complete", "list"],
				"description": "The action to perform."
			},
			"content": {
				"type": "string",
				"description": "The todo item or execution step. **Add each todo item or execution step separately**."
			},
			"path": {
				"type": "string",
				"description": "Required. The full path to the current workspace `TODO.md` file (e.g. 'res://current_workspace_path/TODO.md')."
			}
		},
		"required": ["action", "path"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var action: String = _args.get("action", "")
	var content: String = _args.get("content", "")
	var target_path: String = _args.get("path", "")
	
	# 1. 基础参数检查
	if target_path.is_empty():
		return {"success": false, "data": "Error: 'path' parameter is required."}
	
	# 2. 安全性检查
	if not target_path.begins_with("res://"):
		return {"success": false, "data": "Error: Path must start with 'res://'."}
	if ".." in target_path:
		return {"success": false, "data": "Error: Path traversal ('..') is not allowed."}
	if target_path.get_extension().to_lower() != "md":
		return {"success": false, "data": "Error: Only .md files are supported for TODO lists."}
	
	# 3. 检查文件是否存在
	if not FileAccess.file_exists(target_path):
		# 如果操作是 'add' 或 'list'，则允许创建新文件
		if action == "add" or action == "list":
			# 确保目录存在
			var base_dir: String = target_path.get_base_dir()
			if not DirAccess.dir_exists_absolute(base_dir):
				return {"success": false, "data": "Error: Directory does not exist: " + base_dir}
			
			var file: FileAccess = FileAccess.open(target_path, FileAccess.WRITE)
			if file:
				file.store_string("# Project TODOs\n")
				file.close()
				#ToolBox.update_editor_filesystem(target_path)
				ToolBox.refresh_editor_filesystem()
				
				# 如果是 list 操作，创建完直接返回空列表提示
				if action == "list":
					return {"success": true, "data": "Created new TODO list at %s. It is currently empty." % target_path}
			else:
				return {"success": false, "data": "Failed to create file at: " + target_path}
		else:
			# 对于 'complete'，文件必须存在
			return {"success": false, "data": "File not found: " + target_path}
	
	match action:
		"add":
			if content.is_empty():
				return {"success": false, "data": "Content is required for 'add' action."}
			
			var file: FileAccess = FileAccess.open(target_path, FileAccess.READ_WRITE)
			if file:
				file.seek_end()
				var line: String = "- [ ] %s\n" % content
				
				# 确保新行前有换行符
				if file.get_length() > 0:
					file.seek(file.get_length() - 1)
					if file.get_8() != 10: # \n
						file.store_string("\n")
				
				file.store_string(line)
				file.close()
				ToolBox.update_editor_filesystem(target_path)
				#ToolBox.refresh_editor_filesystem()
				return {"success": true, "data": "Added to %s: %s" % [target_path, content]}
			else:
				return {"success": false, "data": "Failed to open file for writing: " + target_path}
		
		"complete":
			if content.is_empty():
				return {"success": false, "data": "Content is required for 'complete' action."}
			
			var file_read: FileAccess = FileAccess.open(target_path, FileAccess.READ)
			if not file_read: return {"success": false, "data": "Failed to read file: " + target_path}
			
			var original_text: String = file_read.get_as_text()
			var lines: PackedStringArray = original_text.split("\n")
			var new_lines: PackedStringArray = []
			var updated_count: int = 0
			
			for line in lines:
				if content in line and "[ ]" in line:
					line = line.replace("[ ]", "[x]")
					updated_count += 1
				new_lines.append(line)
			
			if updated_count > 0:
				var file_write: FileAccess = FileAccess.open(target_path, FileAccess.WRITE)
				file_write.store_string("\n".join(new_lines))
				file_write.close()
				ToolBox.update_editor_filesystem(target_path)
				#ToolBox.refresh_editor_filesystem()
				return {"success": true, "data": "Marked %d task(s) as completed in %s." % [updated_count, target_path]}
			else:
				return {"success": false, "data": "No open task found containing '%s' in %s." % [content, target_path]}
		
		"list":
			var file: FileAccess = FileAccess.open(target_path, FileAccess.READ)
			if file:
				var text: String = file.get_as_text()
				if text.is_empty():
					return {"success": true, "data": "TODO list (%s) is empty." % target_path}
				return {"success": true, "data": "Content of %s:\n\n%s" % [target_path, text]}
			else:
				return {"success": false, "data": "Failed to read file: " + target_path}
		
		_:
			return {"success": false, "data": "Unknown action: " + action}
