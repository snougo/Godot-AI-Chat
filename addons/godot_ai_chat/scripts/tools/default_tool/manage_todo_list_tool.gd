@tool
extends AiTool

## 管理项目中的待办事项（TODO List）。
## 数据统一存储在插件目录下的 'todo_list.tres' 中，但支持按工作区上下文(context)进行筛选。


# --- Constants ---

## 全局唯一的存储路径
const TODO_RESOURCE_PATH = "res://addons/godot_ai_chat/todo_list.tres"


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "manage_todo_list"
	tool_description = "Listing tasks / Adding new tasks / Marking existing ones as complete. Tasks are stored globally but filtered by workspace context."


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
				"description": "The todo item content. Required for 'add' and 'complete'."
			},
			"path": {
				"type": "string",
				"description": "Required. The current workspace path."
			}
		},
		"required": ["action", "path"]
	}


## 执行 TODO 列表管理操作
func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")
	var content: String = p_args.get("content", "")
	var workspace_path: String = p_args.get("path", "")
	
	# 1. 参数校验
	if workspace_path.is_empty():
		return {"success": false, "data": "Error: 'path' parameter is required (e.g. current folder path)."}
	
	# 统一格式，确保标签一致性
	if not workspace_path.ends_with("/"):
		workspace_path += "/"
	
	# 2. 资源加载 (始终加载全局唯一的那个文件)
	var todo_list: TodoList
	
	# 优先尝试获取缓存实例 (实现实时刷新)
	if ResourceLoader.has_cached(TODO_RESOURCE_PATH):
		todo_list = ResourceLoader.load(TODO_RESOURCE_PATH, "Resource", ResourceLoader.CACHE_MODE_REUSE)
	elif FileAccess.file_exists(TODO_RESOURCE_PATH):
		todo_list = ResourceLoader.load(TODO_RESOURCE_PATH, "Resource")
	
	# 如果资源不存在，或加载失败，则新建
	if not todo_list:
		if action == "add" or action == "list":
			todo_list = TodoList.new()
			# 新建后立即保存一次，确保持久化
			var save_err = _save_resource(todo_list)
			if not save_err.is_empty():
				return {"success": false, "data": "Error initializing TodoList: " + save_err}
		else:
			return {"success": false, "data": "Error: Global TodoList not found. Add a task first."}
	
	# 3. 执行分发
	match action:
		"list":
			return _list_tasks(todo_list, workspace_path)
		"add":
			return _add_task(todo_list, content, workspace_path)
		"complete":
			return _complete_task(todo_list, content) 
		_:
			return {"success": false, "data": "Unknown action: " + action}


# --- Private Functions ---

func _list_tasks(p_todo_list: TodoList, p_workspace_path: String) -> Dictionary:
	# 使用 workspace_path 进行过滤
	var items: Array[TodoItem] = p_todo_list.get_items(p_workspace_path)
	var md_lines: PackedStringArray = []
	md_lines.append("# TODO List (Context: %s)" % p_workspace_path)
	
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


func _add_task(p_todo_list: TodoList, p_content: String, p_workspace_path: String) -> Dictionary:
	if p_content.strip_edges().is_empty():
		return {"success": false, "data": "Error: Content cannot be empty."}
	
	# 添加时带上 workspace_path
	p_todo_list.add_item(p_content, p_workspace_path)
	
	p_todo_list.emit_changed()
	var save_result: String = _save_resource(p_todo_list)
	
	if not save_result.is_empty():
		return {"success": false, "data": "Error saving resource: " + save_result}
	
	return {"success": true, "data": "Added task to context '%s'" % p_workspace_path}


func _complete_task(p_todo_list: TodoList, p_content_match: String) -> Dictionary:
	if p_content_match.strip_edges().is_empty():
		return {"success": false, "data": "Error: Content match string cannot be empty."}
		
	var found: bool = p_todo_list.mark_as_completed(p_content_match)
	if found:
		p_todo_list.emit_changed()
		var save_result: String = _save_resource(p_todo_list)
		if not save_result.is_empty():
			return {"success": false, "data": "Error saving resource: " + save_result}
		return {"success": true, "data": "Marked task as completed."}
	else:
		return {"success": false, "data": "Error: Task containing '%s' not found." % p_content_match}


func _save_resource(p_res: Resource) -> String:
	# 确保目录存在
	var dir = TODO_RESOURCE_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
		
	var error: int = ResourceSaver.save(p_res, TODO_RESOURCE_PATH)
	if error != OK:
		return "ResourceSaver failed with error code: %d" % error
	
	ToolBox.update_editor_filesystem(TODO_RESOURCE_PATH)
	return ""
