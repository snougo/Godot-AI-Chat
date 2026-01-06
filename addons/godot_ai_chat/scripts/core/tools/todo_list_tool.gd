@tool
extends AiTool

const DEFAULT_FILE_PATH: String = "res://addons/godot_ai_chat/TODO.md"


func _init() -> void:
	name = "todo_list"
	description = "Access a TODO.md file. Use 'add' to append, 'complete' to mark done, and 'list' to read. Supports optional file path."


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
				"description": "The text content. Required for 'add' (new task text) and 'complete' (text to match existing task)."
			},
			"path": {
				"type": "string",
				"description": "Optional relative path to the `TODO.md` file (e.g., 'res://The current workspace path/TODO.md')."
			}
		},
		"required": ["action"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var action: String = _args.get("action", "")
	var content: String = _args.get("content", "")
	var target_path: String = _args.get("path", "")
	
	if target_path.is_empty():
		target_path = DEFAULT_FILE_PATH
	
	# [新增] 安全检查：仅允许 .md 或 .txt 文件
	var ext = target_path.get_extension().to_lower()
	if ext != "md":
		return {"success": false, "data": "Security Error: 'todo_list' tool only supports `.md` files. Invalid path: " + target_path}
	
	# 检查文件是否存在
	if not FileAccess.file_exists(target_path):
		# 如果是默认文件，或者操作是 'add'，则尝试创建文件
		if target_path == DEFAULT_FILE_PATH or action == "add":
			var file = FileAccess.open(target_path, FileAccess.WRITE)
			if file:
				file.store_string("# Project TODOs\n")
				file.close()
				ToolBox.refresh_editor_filesystem()
			else:
				return {"success": false, "data": "Failed to create/access file at: " + target_path}
		else:
			# 如果是读取自定义路径且文件不存在，返回错误
			return {"success": false, "data": "File not found: " + target_path}
	
	match action:
		"add":
			if content.is_empty():
				return {"success": false, "data": "Content is required for 'add' action."}
			
			var file = FileAccess.open(target_path, FileAccess.READ_WRITE)
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
				ToolBox.refresh_editor_filesystem()
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
				ToolBox.refresh_editor_filesystem()
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
