@tool
extends AiTool

## 移动文件或目录到新的目标路径。
## 如果目标是已存在的文件夹，项目将被移动到该文件夹内。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "move_file"
	tool_description = "Moves a file or directory to a new target path."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"source_path": {
				"type": "string",
				"description": "The full source path (file or folder) starting with 'res://'."
			},
			"target_path": {
				"type": "string",
				"description": "The full target path. Can be a target folder or a file path."
			}
		},
		"required": ["source_path", "target_path"]
	}


## 执行文件/目录移动操作
## [param p_args]: 包含 source_path 和 target_path 的参数字典
## [return]: 包含成功状态和操作结果的字典
func execute(p_args: Dictionary) -> Dictionary:
	var source_path: String = p_args.get("source_path", "")
	var target_path: String = p_args.get("target_path", "")
	
	if source_path.is_empty() or target_path.is_empty():
		return {"success": false, "data": "Error: Both source_path and target_path are required."}
	
	var validation_result: Dictionary = _validate_paths(source_path, target_path)
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


# --- Private Functions ---

## 验证源路径和目标路径的安全性
## [param p_source_path]: 源路径
## [param p_target_path]: 目标路径
## [return]: 验证结果字典
func _validate_paths(p_source_path: String, p_target_path: String) -> Dictionary:
	var safety_err: String = validate_path_safety(p_source_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	safety_err = validate_path_safety(p_target_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	return {"success": true}


## 获取源路径信息
## [param p_source_path]: 源路径
## [return]: 包含 exists 和 is_dir 的信息字典
func _get_source_info(p_source_path: String) -> Dictionary:
	var is_dir: bool = DirAccess.dir_exists_absolute(p_source_path)
	var is_file: bool = FileAccess.file_exists(p_source_path)
	return {"exists": is_dir or is_file, "is_dir": is_dir}


## 构建目标路径
## [param p_target_path]: 原始目标路径
## [param p_source_path]: 源路径
## [return]: 最终目标路径
func _build_target_path(p_target_path: String, p_source_path: String) -> String:
	if DirAccess.dir_exists_absolute(p_target_path):
		return p_target_path.path_join(p_source_path.get_file())
	return p_target_path


## 检查目标路径是否可用
## [param p_target_path]: 目标路径
## [return]: 检查结果字典
func _check_target_availability(p_target_path: String) -> Dictionary:
	if DirAccess.dir_exists_absolute(p_target_path) or FileAccess.file_exists(p_target_path):
		return {"success": false, "data": "Error: Target already exists at " + p_target_path}
	
	var target_base_dir: String = p_target_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(target_base_dir):
		return {"success": false, "data": "Error: Target parent directory does not exist: " + target_base_dir}
	
	return {"success": true}


## 执行移动操作
## [param p_source_path]: 源路径
## [param p_target_path]: 目标路径
## [return]: 操作结果字典
func _perform_move(p_source_path: String, p_target_path: String) -> Dictionary:
	var err: Error = DirAccess.rename_absolute(p_source_path, p_target_path)
	if err != OK:
		return {"success": false, "data": "Failed to move. Error code: " + str(err)}
	
	ToolBox.refresh_editor_filesystem()
	return {"success": true, "data": "Successfully moved '%s' to '%s'." % [p_source_path, p_target_path]}
