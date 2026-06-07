@tool
extends AiTool

## 查看特定工作区中的未完成待办事项。
## 自动创建空 todo_list.tres 文件（如果不存在）。


func _init() -> void:
	tool_name = "check_todo_list"
	tool_description = "Check pending TODO items in current workspace."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Required. The current workspace path to view todos from."
			}
		},
		"required": ["path"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var workspace_path: String = p_args.get("path", "")
	
	# 参数校验
	if workspace_path.is_empty():
		return {"success": false, "data": "Error: 'path' parameter is required (e.g., current folder path)."}
	
	# 统一路径格式
	if not workspace_path.ends_with("/"):
		workspace_path += "/"
	
	# 加载 TodoList 资源（自动创建空文件）
	var todo_list := _load_or_create_todo_list(workspace_path)
	if todo_list == null:
		return {"success": false, "data": "Error: Failed to initialize TodoList."}
	
	# 获取并返回待办列表
	return _list_pending_tasks(todo_list, workspace_path)


func _load_or_create_todo_list(p_workspace_path: String) -> AiTodoList:
	var todo_list: AiTodoList = null
	
	# 使用动态路径加载 TodoList（根据工作区生成文件路径）
	var todo_list_path: String = PluginPaths.get_todo_list_path(p_workspace_path)
	
	# 强制从磁盘加载，忽略缓存（避免编辑器编辑冲突）
	if ResourceLoader.has_cached(todo_list_path):
		todo_list = ResourceLoader.load(todo_list_path, "Resource", ResourceLoader.CACHE_MODE_IGNORE)
	elif FileAccess.file_exists(todo_list_path):
		todo_list = ResourceLoader.load(todo_list_path, "Resource")
	
	# 如果文件不存在，自动创建空的 TodoList
	if not todo_list:
		todo_list = AiTodoList.new()
		var save_error := _save_resource(todo_list, p_workspace_path)
		if not save_error.is_empty():
			printerr("TodoList 初始化失败：%s" % save_error)
			return null
	
	# 刷新缓存，确保获取最新数据
	if ResourceLoader.has_cached(todo_list_path):
		todo_list = ResourceLoader.load(todo_list_path, "Resource", ResourceLoader.CACHE_MODE_IGNORE)
	
	return todo_list


func _list_pending_tasks(p_todo_list: AiTodoList, p_workspace_path: String) -> Dictionary:
	var items: Array[AiTodoItem] = p_todo_list.get_items(p_workspace_path)
	var md_lines: PackedStringArray = []
	
	md_lines.append("##📋 TODO List")
	md_lines.append("**Workspace**: `%s`\n" % p_workspace_path)
	
	var pending_tasks: Array[AiTodoItem] = []
	var completed_count: int = 0
	
	for item in items:
		if not item.is_completed:
			pending_tasks.append(item)
		else:
			completed_count += 1
	
	# 显示未完成任务
	if pending_tasks.is_empty():
		md_lines.append("✅ **No pending TODO items in current workspace**")
	else:
		md_lines.append("**Pending (%d)**:\n" % pending_tasks.size())
		for i in range(pending_tasks.size()):
			var task := pending_tasks[i]
			md_lines.append("%d. [ ] %s" % [i + 1, task.content])
	
	# 显示统计信息
	md_lines.append("\n---")
	md_lines.append("📊 **Stats**: Pending %d | Completed %d | Total %d" % [pending_tasks.size(), completed_count, items.size()])
	
	return {"success": true, "data": "\n".join(md_lines)}


func _save_resource(p_res: Resource, p_workspace_path: String) -> String:
	var todo_list_path: String = PluginPaths.get_todo_list_path(p_workspace_path)
	var dir := todo_list_path.get_base_dir()
	
	# 确保目录存在
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	
	var error := ResourceSaver.save(p_res, todo_list_path)
	if error != OK:
		return "ResourceSaver failed with error code: %d" % error
	
	# 刷新编辑器文件系统
	ToolBox.update_editor_filesystem(todo_list_path)
	return ""
