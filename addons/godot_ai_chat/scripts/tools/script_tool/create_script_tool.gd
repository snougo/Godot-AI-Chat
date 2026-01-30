@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "create_script"
	tool_description = "Create a new .gd or .gdshader script file."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"folder_path": { "type": "string", "description": "Target folder path (e.g. 'res://xxxxxx/')." },
			"file_name": { "type": "string", "description": "File name with extension (e.g. 'xxxxxx.gd')." },
			"content": { "type": "string", "description": "Initial code content." }
		},
		"required": ["folder_path", "file_name", "content"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var folder: String = p_args.get("folder_path", "")
	var name: String = p_args.get("file_name", "")
	var content: String = p_args.get("content", "")
	
	if not folder.ends_with("/"):
		folder += "/"
	var full_path := folder + name
	
	# 安全与校验
	var safety_err := validate_path_safety(full_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	var ext_err := validate_file_extension(full_path)
	if not ext_err.is_empty():
		return {"success": false, "data": ext_err}
	
	if FileAccess.file_exists(full_path):
		return {"success": false, "data": "Error: File already exists at %s" % full_path}
		
	if not DirAccess.dir_exists_absolute(folder):
		return {"success": false, "data": "Error: Directory does not exist: %s" % folder}
	
	# 写入文件
	var file := FileAccess.open(full_path, FileAccess.WRITE)
	if not file:
		return {"success": false, "data": "Failed to write file."}
	file.store_string(content)
	file.close()
	
	# 刷新并打开
	ToolBox.update_editor_filesystem(full_path)
	var code_edit := _get_code_edit(full_path)
	
	var view := ""
	if code_edit:
		view = get_sliced_code_view(code_edit)
	else:
		view = "(Failed to open editor automatically, but file was created)"
	
	return {"success": true, "data": "Created %s.\n\n%s" % [full_path, view]}
