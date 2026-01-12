@tool
extends AiTool

func _init() -> void:
	tool_name = "create_folder"
	tool_description = "Create a new folder (directory) at the specified path. Support creating nested directories (e.g., res://a/b/c)."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path where the folder should be created."
			}
		},
		"required": ["path"]
	}


func execute(_args: Dictionary, _context_provider: Object) -> Dictionary:
	var path: String = _args.get("path", "")
	
	# 标准化路径分隔符
	path = path.replace("\\", "/")
	# 去除末尾斜杠以方便后续统一处理
	if path.ends_with("/"):
		path = path.left(-1)
	
	# 调用AiTool基类方法进行安全检查
	# 如果通过路径安全检查，则返回一个空字符串
	# 如果安全检查失败，则返回对应的错误信息
	var security_error: String = validate_path_safety(path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	var dir: DirAccess = DirAccess.open("res://")
	if dir == null:
		return {"success": false, "data": "Failed to access file system."}
	
	# 检查同路径下是否已存在同名文件夹
	if dir.dir_exists(path):
		return {"success": true, "data": "Folder already exists: %s" % path}
	
	var err: Error = dir.make_dir_recursive(path)
	if err == OK:
		ToolBox.update_editor_filesystem(path)
		ToolBox.refresh_editor_filesystem()
		return {"success": true, "data": "Successfully created folder: %s" % path}
	else:
		return {"success": false, "data": "Failed to create folder. Error code: %s" % str(err)}
