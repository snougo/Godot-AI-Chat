@tool
extends AiTool


func _init() -> void:
	name = "create_script"
	description = "Create a new GDScript file with the specified content. The filename will be automatically suffixed with '-ai_create'."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The target file path (e.g., 'res://xxxxxx/my_script.gd')."
			},
			"content": {
				"type": "string",
				"description": "The GDScript code content to write."
			}
		},
		"required": ["path", "content"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path: String = _args.get("path", "")
	var content: String = _args.get("content", "")
	
	if path.is_empty():
		return {"success": false, "data": "Error: 'path' parameter is required."}
	
	if not path.begins_with("res://"):
		return {"success": false, "data": "Error: Path must start with 'res://'."}
	
	# 1. 处理文件名：添加 -ai_create 后缀
	var extension: String = path.get_extension()
	var base_path: String = path.get_basename()
	
	# 如果没后缀，默认 .gd
	if extension.is_empty():
		extension = "gd"
	
	# 防止重复添加后缀
	if not base_path.ends_with("-ai_create"):
		base_path += "-ai_create"
	
	var final_path := base_path + "." + extension
	
	# 2. 确保目录存在
	var dir_access = DirAccess.open("res://")
	var base_dir: String = final_path.get_base_dir()
	
	if not dir_access.dir_exists(base_dir):
		var err: Error = dir_access.make_dir_recursive(base_dir)
		if err != OK:
			return {"success": false, "data": "Error: Failed to create directory " + base_dir}
	
	# 3. 写入文件
	var file: FileAccess = FileAccess.open(final_path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "data": "Error: Failed to open file for writing: " + str(FileAccess.get_open_error())}
	
	file.store_string(content)
	file.close()
	
	# 4. 刷新编辑器资源 (如果在编辑器中运行)
	if Engine.is_editor_hint():
		var fs: EditorFileSystem = EditorInterface.get_resource_filesystem()
		if fs:
			fs.scan()
	
	return {"success": true, "data": "Script created successfully at: " + final_path}
