@tool
extends AiTool

## 移动单一文件到新的目标路径。
## 注意：本工具仅支持移动文件，不支持移动文件夹。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "move_file"
	tool_description = "Moves a single file to a new target path. Folders are not supported."
	security_level = SecurityLevel.PATH_VALIDATED


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"source_path": {
				"type": "string",
				"description": "The full source file path starting with 'res://'."
			},
			"target_path": {
				"type": "string",
				"description": "The full target path. Can be a target folder or a file path."
			}
		},
		"required": ["source_path", "target_path"]
	}


## 执行文件移动操作
func execute(p_args: Dictionary) -> ToolResult:
	var source_path: String = p_args.get("source_path", "")
	var target_path: String = p_args.get("target_path", "")
	
	if source_path.is_empty() or target_path.is_empty():
		return ToolResult.fail("Error: Both source_path and target_path are required.")
	
	var validation_result: Dictionary = _validate_paths(source_path, target_path)
	if not validation_result.get("success", false):
		return ToolResult.fail(validation_result.data)
	
	# 仅允许移动文件，拒绝移动目录
	if DirAccess.dir_exists_absolute(source_path):
		return ToolResult.fail("Error: '%s' is a folder, not a file." % source_path)
	
	if not FileAccess.file_exists(source_path):
		return ToolResult.fail("Error: Source file not found at " + source_path)
	
	target_path = _build_target_path(target_path, source_path)
	
	# 校验文件名一致性，防止重命名
	var name_check: Dictionary = _validate_filename_consistency(source_path, target_path)
	if not name_check.get("success", false):
		return ToolResult.fail(name_check.data)
	
	var target_check_result: Dictionary = _check_target_availability(target_path)
	if not target_check_result.get("success", false):
		return ToolResult.fail(target_check_result.data)
	
	return _perform_move(source_path, target_path)


# --- Private Functions ---

# 验证源路径和目标路径的安全性
func _validate_paths(p_source_path: String, p_target_path: String) -> Dictionary:
	var safety_err: String = validate_path_safety(p_source_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	safety_err = validate_path_safety(p_target_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	return {"success": true}


# 检查目标文件名是否与源文件名一致（防止模型借此实现重命名）
func _validate_filename_consistency(p_source_path: String, p_target_path: String) -> Dictionary:
	var source_file: String = p_source_path.get_file()
	var target_file: String = p_target_path.get_file()
	
	if source_file != target_file:
		return {
			"success": false,
			"data": "Error: Renaming files is not allowed. Source filename '%s' must match target filename '%s'." % [source_file, target_file]
		}
	return {"success": true}


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
func _perform_move(p_source_path: String, p_target_path: String) -> ToolResult:
	var err: Error = DirAccess.rename_absolute(p_source_path, p_target_path)
	if err != OK:
		return ToolResult.fail("Failed to move. Error code: " + str(err))
	
	ToolBox.refresh_editor_filesystem()
	return ToolResult.ok("Successfully moved file '%s' to '%s'." % [p_source_path, p_target_path])
