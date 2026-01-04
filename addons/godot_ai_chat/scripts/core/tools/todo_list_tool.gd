@tool
extends AiTool

const TODO_FILE_PATH: String = "res://addons/godot_ai_chat/todo_list.json"


func _init() -> void:
	name = "todo_list"
	description = "Manage a structured list of actionable tasks. **ALWAYS use this tool** to track what needs to be done and implementation progress. **Prefer this over writing plans in the notebook**."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["add", "complete", "remove", "list", "clear"],
				"description": "The action to perform on the todo list."
			},
			"task_content": {
				"type": "string",
				"description": "The description of the task. Required when action is 'add'."
			},
			"task_index": {
				"type": "integer",
				"description": "The 0-based index of the task to update or remove. Required when action is 'complete' or 'remove'."
			}
		},
		"required": ["action"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var action: String = _args.get("action", "")
	var task_content: String = _args.get("task_content", "")
	# JSON numbers are floats, cast to int. Default to -1.
	var task_index: int = int(_args.get("task_index", -1))
	
	var todos: Array = _load_todos()
	var result_msg: String = ""
	var success: bool = true
	
	match action:
		"add":
			if task_content.is_empty():
				return {"success": false, "data": "task_content is required for 'add' action."}
			todos.append({"task": task_content, "status": "pending"})
			if _save_todos(todos):
				result_msg = "Task added: " + task_content
			else:
				success = false
				result_msg = "Failed to save todo list."
		
		"complete":
			if task_index < 0 or task_index >= todos.size():
				return {"success": false, "data": "Invalid task_index: %d. List size: %d" % [task_index, todos.size()]}
			todos[task_index]["status"] = "completed"
			if _save_todos(todos):
				result_msg = "Task completed: " + todos[task_index]["task"]
			else:
				success = false
				result_msg = "Failed to save todo list."
		
		"remove":
			if task_index < 0 or task_index >= todos.size():
				return {"success": false, "data": "Invalid task_index: %d. List size: %d" % [task_index, todos.size()]}
			var removed_task = todos.pop_at(task_index)
			if _save_todos(todos):
				result_msg = "Task removed: " + removed_task["task"]
			else:
				success = false
				result_msg = "Failed to save todo list."
		
		"list":
			if todos.is_empty():
				result_msg = "Todo list is empty."
			else:
				result_msg = "Current Todo List:\n"
				for i in range(todos.size()):
					var item = todos[i]
					var status_mark = "[x]" if item["status"] == "completed" else "[ ]"
					result_msg += "%d. %s %s\n" % [i, status_mark, item["task"]]
		
		"clear":
			todos.clear()
			if _save_todos(todos):
				result_msg = "Todo list cleared."
			else:
				success = false
				result_msg = "Failed to save todo list."
		
		_:
			return {"success": false, "data": "Unknown action: " + action}
	
	return {"success": success, "data": result_msg}


func _load_todos() -> Array:
	if not FileAccess.file_exists(TODO_FILE_PATH):
		return []
	
	var file = FileAccess.open(TODO_FILE_PATH, FileAccess.READ)
	if not file:
		push_error("Failed to open todo list file for reading.")
		return []
	
	var content = file.get_as_text()
	if content.is_empty():
		return []
	
	var json = JSON.new()
	var error = json.parse(content)
	if error == OK:
		if json.data is Array:
			return json.data
		else:
			push_warning("Todo list file content is not an array.")
			return []
	else:
		push_error("Failed to parse todo list JSON: error code " + str(error))
		return []


func _save_todos(todos: Array) -> bool:
	var file = FileAccess.open(TODO_FILE_PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(todos, "\t"))
		return true
	else:
		push_error("Failed to open todo list file for writing.")
		return false
