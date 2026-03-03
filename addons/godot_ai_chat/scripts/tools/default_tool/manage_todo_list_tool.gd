@tool
extends AiTool

## 管理项目中的待办事项（Todo List）。
## 支持添加新任务和标记任务完成。

func _init() -> void:
	tool_name = "manage_todo_list"
	tool_description = "Adding new tasks / Marking existing ones as complete. Tasks are stored per workspace."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["add", "complete"],
				"description": "The action to perform."
			},
			"content": {
				"type": "string",
				"description": "The todo item content. Required for 'add' and 'complete'."
			},
			"path": {
				"type": "string",
				"description": "Required. The current workspace path."
			}
		},
		"required": ["action", "content", "path"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")
	var content: String = p_args.get("content", "")
	var workspace_path: String = p_args.get("path", "")
	
	# 参数校验
	if workspace_path.is_empty():
		return {"success": false, "data": "Error: 'path' parameter is required (e.g. current folder path)."}
	
	# 统一路径格式
	if not workspace_path.ends_with("/"):
		workspace_path += "/"
	
	# 加载或创建 TodoList 资源（使用动态路径）
	var todo_list := _load_or_create_todo_list(action == "add", workspace_path)
	if todo_list == null:
		return {"success": false, "data": "Error: Failed to initialize TodoList."}
	
	# 执行操作
	match action:
		"add":
			return _add_task(todo_list, content, workspace_path)
		"complete":
			return _complete_task(todo_list, content, workspace_path)
		_:
			return {"success": false, "data": "Unknown action: " + action}


func _load_or_create_todo_list(p_create_if_missing: bool, p_workspace_path: String) -> AiTodoList:
	var todo_list: AiTodoList = null
	
	# 使用动态路径加载 TodoList（根据工作区生成文件路径）
	var todo_list_path: String = PluginPaths.get_todo_list_path(p_workspace_path)
	
	# 强制从磁盘加载，忽略缓存（避免编辑器编辑冲突）
	if ResourceLoader.has_cached(todo_list_path):
		todo_list = ResourceLoader.load(todo_list_path, "Resource", ResourceLoader.CACHE_MODE_IGNORE)
	elif FileAccess.file_exists(todo_list_path):
		todo_list = ResourceLoader.load(todo_list_path, "Resource")
	
	# 创建新资源（如果不存在）
	if not todo_list and p_create_if_missing:
		todo_list = AiTodoList.new()
		if not _save_resource(todo_list, p_workspace_path).is_empty():
			return null
	
	return todo_list


func _list_tasks(p_todo_list: AiTodoList, p_workspace_path: String) -> Dictionary:
	var items: Array[AiTodoItem] = p_todo_list.get_items(p_workspace_path)
	var md_lines: PackedStringArray = []
	md_lines.append("# TODO List")
	
	var active_tasks_count: int = 0
	
	for item in items:
		if not item.is_completed:
			md_lines.append("- [ ] %s" % item.content)
			active_tasks_count += 1
	
	if active_tasks_count == 0:
		if items.is_empty():
			md_lines.append("- (No tasks active in this context)")
		else:
			md_lines.append("- (All tasks in this context are completed)")
	
	return {"success": true, "data": "\n".join(md_lines)}


func _add_task(p_todo_list: AiTodoList, p_content: String, p_workspace_path: String) -> Dictionary:
	if p_content.strip_edges().is_empty():
		return {"success": false, "data": "Error: Content cannot be empty."}
	
	p_todo_list.add_item(p_content, p_workspace_path)
	p_todo_list.emit_changed()
	
	var save_error := _save_resource(p_todo_list, p_workspace_path)
	if not save_error.is_empty():
		return {"success": false, "data": "Error saving resource: " + save_error}
	
	# 添加成功后，返回当前所有未完成待办
	var result_msg: String = "✅ Added task to Workspace '%s'\n\n---\n\n" % p_workspace_path
	var list_result: Dictionary = _list_tasks(p_todo_list, p_workspace_path)
	result_msg += list_result.data
	
	return {"success": true, "data": result_msg}


func _complete_task(p_todo_list: AiTodoList, p_content_match: String, p_workspace_path: String) -> Dictionary:
	if p_content_match.strip_edges().is_empty():
		return {"success": false, "data": "Error: Content match string cannot be empty."}
	
	var found := p_todo_list.mark_as_completed(p_content_match)
	if not found:
		return {"success": false, "data": "Error: Task containing '%s' not found." % p_content_match}
	
	p_todo_list.emit_changed()
	
	var save_error := _save_resource(p_todo_list, p_workspace_path)
	if not save_error.is_empty():
		return {"success": false, "data": "Error saving resource: " + save_error}
	
	# 完成后，返回当前所有未完成待办（显示被标记完成的任务）
	var result_msg: String = "✅ `%s` task marked as completed in Workspace '%s'\n\n---\n\n" % [p_content_match, p_workspace_path]
	var list_result: Dictionary = _list_tasks(p_todo_list, p_workspace_path)
	result_msg += list_result.data
	
	return {"success": true, "data": result_msg}


func _save_resource(p_res: Resource, p_workspace_path: String) -> String:
	var todo_list_path: String = PluginPaths.get_todo_list_path(p_workspace_path)
	var dir := todo_list_path.get_base_dir()
	
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	
	var error := ResourceSaver.save(p_res, todo_list_path)
	if error != OK:
		return "ResourceSaver failed with error code: %d" % error
	
	ToolBox.update_editor_filesystem(todo_list_path)
	return ""
