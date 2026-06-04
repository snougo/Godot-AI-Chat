@tool
extends AiTool

## 文件夹综合管理工具。
## 本AI工的部分功能依赖第三方Godot插件 Context Toolkit


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "manage_folder"
	tool_description = "Manages folders and directories."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["list", "create", "move"],
				"description": "The operation to perform: 'list' to view folder structure, 'create' to create a new folder, 'move' to move a file or directory."
			},
			"path": {
				"type": "string",
				"description": "The folder path. Required for actions 'list' and 'create'."
			},
			"source_path": {
				"type": "string",
				"description": "The source path (file or folder). Required for action 'move'."
			},
			"target_path": {
				"type": "string",
				"description": "The target path. Required for action 'move'."
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
		"move":
			return _handle_move(p_args)
		_:
			return {"success": false, "data": "Error: Unknown action '%s'. Valid actions: list, create, move." % action}


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


# 处理文件/文件夹移动操作
func _handle_move(p_args: Dictionary) -> Dictionary:
	var source_path: String = p_args.get("source_path", "")
	var target_path: String = p_args.get("target_path", "")
	
	if source_path.is_empty() or target_path.is_empty():
		return {"success": false, "data": "Error: Both 'source_path' and 'target_path' are required for action 'move'."}
	
	var validation_result: Dictionary = _validate_move_paths(source_path, target_path)
	if not validation_result.get("success", false):
		return validation_result
	
	var source_info: Dictionary = _get_source_info(source_path)
	if not source_info.get("exists", false):
		return {"success": false, "data": "Error: Source not found at " + source_path}
	
	target_path = _build_target_path(target_path, source_path)
	
	var target_check_result: Dictionary = _check_target_availability(target_path)
	if not target_check_result.get("success", false):
		return target_check_result
	
	return _perform_move(source_path, target_path)


# ==================== Shared Utilities ====================

# 标准化路径格式
# [param p_path]: 原始路径
# [return]: 标准化后的路径
func _normalize_path(p_path: String) -> String:
	var normalized: String = p_path.replace("\\", "/")
	if normalized.ends_with("/"):
		normalized = normalized.left(-1)
	return normalized


# 验证移动操作的源路径和目标路径
func _validate_move_paths(p_source_path: String, p_target_path: String) -> Dictionary:
	var safety_err: String = validate_path_safety(p_source_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	safety_err = validate_path_safety(p_target_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	return {"success": true}


# 获取源路径信息
func _get_source_info(p_source_path: String) -> Dictionary:
	var is_dir: bool = DirAccess.dir_exists_absolute(p_source_path)
	var is_file: bool = FileAccess.file_exists(p_source_path)
	return {"exists": is_dir or is_file, "is_dir": is_dir}


# 构建目标路径（如果目标是已存在的文件夹，则将源移动到其内部）
func _build_target_path(p_target_path: String, p_source_path: String) -> String:
	if DirAccess.dir_exists_absolute(p_target_path):
		return p_target_path.path_join(p_source_path.get_file())
	return p_target_path


# 检查目标路径是否可用
func _check_target_availability(p_target_path: String) -> Dictionary:
	if DirAccess.dir_exists_absolute(p_target_path) or FileAccess.file_exists(p_target_path):
		return {"success": false, "data": "Error: Target already exists at " + p_target_path}
	
	var target_base_dir: String = p_target_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(target_base_dir):
		return {"success": false, "data": "Error: Target parent directory does not exist: " + target_base_dir}
	
	return {"success": true}


# 执行移动操作
func _perform_move(p_source_path: String, p_target_path: String) -> Dictionary:
	var err: Error = DirAccess.rename_absolute(p_source_path, p_target_path)
	if err != OK:
		return {"success": false, "data": "Failed to move. Error code: " + str(err)}
	
	ToolBox.refresh_editor_filesystem()
	return {"success": true, "data": "Successfully moved '%s' to '%s'." % [p_source_path, p_target_path]}
