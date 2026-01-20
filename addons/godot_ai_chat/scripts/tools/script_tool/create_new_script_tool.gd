@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "create_new_script"
	tool_description = "Creates a new empty script. NEXT STEP: Use 'fill_empty_script' to add content."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path where the script should be created."
			}
		},
		"required": ["path"]
	}


func execute(_args: Dictionary) -> Dictionary:
	var new_script_path: String = _args.get("path", "")
	var content: String = "" 
	
	# 1. 路径安全检查
	# 调用AiTool基类方法进行安全检查
	# 如果通过路径安全检查，则返回一个空字符串
	# 如果安全检查失败，则返回对应的错误信息
	var security_error = validate_path_safety(new_script_path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	# 2. 扩展名检查
	# 调用BaseScriptTool基类方法进行安全检查
	var ext_error = validate_file_extension(new_script_path)
	if not ext_error.is_empty():
		return {"success": false, "data": ext_error}
	
	# 3. 额外的安全性检查：禁止路径遍历
	if ".." in new_script_path:
		return {"success": false, "data": "Error: Path traversal ('..') is not allowed."}
	
	# 4. 防止覆盖 (核心约束)
	if FileAccess.file_exists(new_script_path):
		return {"success": false, "data": "Error: File '%s' already exists. this tool cannot overwrite existing files." % new_script_path}
	
	# 5. 自动创建目录
	#var base_dir: String = new_script_path.get_base_dir()
	#var dir_access: DirAccess = DirAccess.open("res://")
	#if not dir_access.dir_exists(base_dir):
		#var err: Error = dir_access.make_dir_recursive(base_dir)
		#if err != OK:
			#return {"success": false, "data": "Error: Failed to create directory " + base_dir}
	
	# 5. 检查目录是否存在
	var base_dir: String = new_script_path.get_base_dir()
	var dir_access: DirAccess = DirAccess.open("res://")
	if not dir_access.dir_exists(base_dir):
		return {"success": false, "data": "Directory not found: %s. Please use 'create_folder' tool first." % base_dir}
	
	# 6. 写入文件
	var file: FileAccess = FileAccess.open(new_script_path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "data": "Error: Failed to open file: " + str(FileAccess.get_open_error())}
	
	file.store_string(content)
	file.close()
	
	# 7. 刷新编辑器资源系统
	ToolBox.update_editor_filesystem(new_script_path)
	
	return {"success": true, "data": "Empty file created successfully at: " + new_script_path}
