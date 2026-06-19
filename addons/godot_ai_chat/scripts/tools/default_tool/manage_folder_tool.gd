@tool
extends AiTool

## 文件夹综合管理工具。
## 本AI工的部分功能依赖第三方Godot插件 Context Toolkit


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "manage_folder"
	tool_description = "Lists and creates folders and directories."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["list", "create"],
				"description": "The operation to perform: 'list' to view folder structure, 'create' to create a new folder."
			},
			"path": {
				"type": "string",
				"description": "The folder path. Required for actions 'list' and 'create'."
			}
		},
		"required": ["action"]
	}


## 执行文件夹操作
## [param p_args]: 包含 action 及相关参数的字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")
	
	match action:
		"list":
			return _handle_list(p_args)
		"create":
			return _handle_create(p_args)
		_:
			return {"success": false, "data": "Error: Unknown action '%s'. Valid actions: list, create." % action}


# --- Private Functions ---

# 处理文件夹结构列出操作
func _handle_list(p_args: Dictionary) -> Dictionary:
	var path: String = p_args.get("path", "")
	if path.is_empty():
		return {"success": false, "data": "Error: 'path' parameter is required for action 'list'."}
	
	#var security_error: String = validate_path_safety(path)
	#if not security_error.is_empty():
		#return {"success": false, "data": security_error}
	
	var dir := DirAccess.open("res://")
	if dir == null:
		return {"success": false, "data": "Failed to access file system."}
	if not dir.dir_exists(path):
		return {"success": false, "data": "Error: Directory not found: " + path}
	
	var context_provider := ContextProvider.new()
	return context_provider.get_folder_structure_as_markdown(path)


# 处理文件夹创建操作
func _handle_create(p_args: Dictionary) -> Dictionary:
	var path: String = p_args.get("path", "")
	if path.is_empty():
		return {"success": false, "data": "Error: 'path' parameter is required for action 'create'."}
	
	path = _normalize_path(path)
	
	var security_error: String = validate_path_safety(path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	var dir := DirAccess.open("res://")
	if dir == null:
		return {"success": false, "data": "Failed to access file system."}
	
	if dir.dir_exists(path):
		return {"success": true, "data": "Folder already exists: %s" % path}
	
	var err: Error = dir.make_dir_recursive(path)
	if err == OK:
		ToolBox.refresh_editor_filesystem()
		return {"success": true, "data": "Successfully created folder: %s" % path}
	else:
		return {"success": false, "data": "Failed to create folder. Error code: %s" % str(err)}


# === Utility Functions ===

# 标准化路径格式
# [param p_path]: 原始路径
# [return]: 标准化后的路径
func _normalize_path(p_path: String) -> String:
	var normalized: String = p_path.replace("\\", "/")
	if normalized.ends_with("/"):
		normalized = normalized.left(-1)
	return normalized
