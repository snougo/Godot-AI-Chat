@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "open_script_in_editor"
	tool_description = "Opens a script file in the Godot Script Editor. Use this before using `get_edited_script` tool if you need to work with a specific file."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_path": { "type": "string", "description": "Full path to the script file (e.g., 'res://current_workspace/xxxx.gd')." }
		},
		"required": ["file_path"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var path: String = p_args.get("file_path", "")
	
	# [Security Check] Validate path against blacklist
	var safety_err: String = validate_path_safety(path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "File not found: %s" % path}
	
	# 检查文件扩展名
	var ext_err := validate_file_extension(path)
	if not ext_err.is_empty():
		return {"success": false, "data": ext_err}
	
	# 加载并打开脚本
	var res = load(path)
	if not res is Script:
		return {"success": false, "data": "The specified file is not a valid script: %s" % path}
	
	EditorInterface.edit_script(res)
	EditorInterface.set_main_screen_editor("Script")
	
	return {"success": true, "data": "Script opened successfully: %s" % path}
