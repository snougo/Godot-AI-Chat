@tool
extends AiTool

## 管理 'TODO.md' 中的任务列表。
## 严格用于可执行项目和进度跟踪。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "todo_list"
	tool_description = "Manage task lists in current workspace 'TODO.md'."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
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
				"description": "Required. The full path to the current workspace `TODO.md` file."
			}
		},
		"required": ["action", "path"]
	}


## 执行 TODO 列表管理操作
## [param p_args]: 包含 action、content 和 path 的参数字典
## [return]: 包含成功状态和操作结果的字典
func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")
	var content: String = p_args.get("content", "")
	var target_path: String = p_args.get("path", "")
	
	if target_path.is_empty():
		return {"success": false, "data": "Error: 'path' parameter is required."}
	
	var validation_result: String = _validate_path(target_path)
	if not validation_result.is_empty():
		return {"success": false, "data": validation_result}
	
	var file_exists: bool = FileAccess.file_exists(target_path)
	
	if not file_exists:
		var create_result: Dictionary = _handle_file_creation(target_path, action)
		if not create_result.is_empty():
			return create_result
	
	match action:
		"add":
			return _add_todo_item(target_path, content)
		"complete":
			return _complete_todo_item(target_path, content)
		"list":
			return _list_todo_items(target_path)
		_:
			return {"success": false, "data": "Unknown action: " + action}


# --- Private Functions ---

## 验证路径安全性和有效性
## [param p_path]: 要验证的路径
## [return]: 空字符串表示有效，否则返回错误信息
func _validate_path(p_path: String) -> String:
	if not p_path.begins_with("res://"):
		return "Error: Path must start with 'res://'."
	if ".." in p_path:
		return "Error: Path traversal ('..') is not allowed."
	if p_path.get_extension().to_lower() != "md":
		return "Error: Only .md files are supported for TODO lists."
	return ""


## 处理文件不存在时的创建逻辑
## [param p_path]: 目标文件路径
## [param p_action]: 当前操作类型
## [return]: 如果需要返回错误则返回字典，否则返回空字典
func _handle_file_creation(p_path: String, p_action: String) -> Dictionary:
	if p_action != "add" and p_action != "list":
		return {"success": false, "data": "File not found: " + p_path}
	
	var base_dir: String = p_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(base_dir):
		return {"success": false, "data": "Error: Directory does not exist: " + base_dir}
	
	var file: FileAccess = FileAccess.open(p_path, FileAccess.WRITE)
	if not file:
		return {"success": false, "data": "Failed to create file at: " + p_path}
	
	file.store_string("# Project TODOs\n")
	file.close()
	# ToolBox为全局静态工具类
	ToolBox.refresh_editor_filesystem()
	
	if p_action == "list":
		return {"success": true, "data": "Created new TODO list at %s. It is currently empty." % p_path}
	
	return {}


## 添加 TODO 项目
## [param p_path]: 目标文件路径
## [param p_content]: 要添加的内容
## [return]: 操作结果字典
func _add_todo_item(p_path: String, p_content: String) -> Dictionary:
	if p_content.is_empty():
		return {"success": false, "data": "Content is required for 'add' action."}
	
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ_WRITE)
	if not file:
		return {"success": false, "data": "Failed to open file for writing: " + p_path}
	
	file.seek_end()
	var line: String = "- [ ] %s\n" % p_content
	
	if file.get_length() > 0:
		file.seek(file.get_length() - 1)
		if file.get_8() != 10: # \n
			file.store_string("\n")
	
	file.store_string(line)
	file.close()
	# ToolBox为全局静态工具
	ToolBox.update_editor_filesystem(p_path)
	
	return {"success": true, "data": "Added to %s: %s" % [p_path, p_content]}


## 完成 TODO 项目
## [param p_path]: 目标文件路径
## [param p_content]: 要标记为完成的内容
## [return]: 操作结果字典
func _complete_todo_item(p_path: String, p_content: String) -> Dictionary:
	if p_content.is_empty():
		return {"success": false, "data": "Content is required for 'complete' action."}
	
	var file_read: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not file_read:
		return {"success": false, "data": "Failed to read file: " + p_path}
	
	var original_text: String = file_read.get_as_text()
	var lines: PackedStringArray = original_text.split("\n")
	var new_lines: PackedStringArray = []
	var updated_count: int = 0
	
	for line in lines:
		if p_content in line and "[ ]" in line:
			line = line.replace("[ ]", "[x]")
			updated_count += 1
		new_lines.append(line)
	
	file_read.close()
	
	if updated_count > 0:
		var file_write: FileAccess = FileAccess.open(p_path, FileAccess.WRITE)
		file_write.store_string("\n".join(new_lines))
		file_write.close()
		# ToolBox为全局静态工具
		ToolBox.update_editor_filesystem(p_path)
		return {"success": true, "data": "Marked %d task(s) as completed in %s." % [updated_count, p_path]}
	else:
		return {"success": false, "data": "No open task found containing '%s' in %s." % [p_content, p_path]}


## 列出所有 TODO 项目
## [param p_path]: 目标文件路径
## [return]: 操作结果字典
func _list_todo_items(p_path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not file:
		return {"success": false, "data": "Failed to read file: " + p_path}
	
	var text: String = file.get_as_text()
	file.close()
	
	if text.is_empty():
		return {"success": true, "data": "TODO list (%s) is empty." % p_path}
	
	return {"success": true, "data": "Content of %s:\n\n%s" % [p_path, text]}
