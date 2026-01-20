@tool
extends AiTool


func _init() -> void:
	tool_name = "move_file"
	tool_description = "Moves a file or directory to a new target path. If target is an existing folder, the item is moved inside it."


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
				"description": "The target path. Can be a target folder or a full new path."
			}
		},
		"required": ["source_path", "target_path"]
	}


func execute(_args: Dictionary) -> Dictionary:
	var source_path: String = _args.get("source_path", "")
	var target_path: String = _args.get("target_path", "")
	
	# 1. 基础验证
	if source_path.is_empty() or target_path.is_empty():
		return {"success": false, "data": "Error: Both source_path and target_path are required."}
	
	# 2. 安全性检查
	var safety_err: String = validate_path_safety(source_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	safety_err = validate_path_safety(target_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	# 3. 确认源是否存在
	# 使用静态方法检查，无需实例化
	var is_source_dir: bool = DirAccess.dir_exists_absolute(source_path)
	var is_source_file: bool = FileAccess.file_exists(source_path)
	
	if not is_source_dir and not is_source_file:
		return {"success": false, "data": "Error: Source not found at " + source_path}
	
	# 4. 智能构建目标路径
	# 如果 target_path 是一个已存在的目录，则自动追加源文件名，实现“移动到文件夹内”的效果
	if DirAccess.dir_exists_absolute(target_path):
		target_path = target_path.path_join(source_path.get_file())
	
	# 5. 防止覆盖检查
	if DirAccess.dir_exists_absolute(target_path) or FileAccess.file_exists(target_path):
		return {"success": false, "data": "Error: Target already exists at " + target_path}
	
	# 6. 确认目标父目录存在
	var target_base_dir: String = target_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(target_base_dir):
		return {"success": false, "data": "Error: Target parent directory does not exist: " + target_base_dir}
	
	# 7. 执行移动
	var err: Error = DirAccess.rename_absolute(source_path, target_path)
	if err != OK:
		return {"success": false, "data": "Failed to move. Error code: " + str(err)}
	
	# 8. 刷新编辑器文件系统
	ToolBox.refresh_editor_filesystem()
	
	return {"success": true, "data": "Successfully moved '%s' to '%s'." % [source_path, target_path]}
