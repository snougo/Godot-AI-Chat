@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "fill_empty_script"
	tool_description = "Writes code to a NEW empty file. For existing files, use 'insert_script_code'."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the new empty script."
			},
			"code_content": {
				"type": "string",
				"description": "The GDScript code to write."
			}
		},
		"required": ["path", "code_content"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path = _args.get("path", "")
	var content = _args.get("code_content", "")
	
	# 1. 路径安全检查
	# 调用AiTool基类方法进行安全检查
	# 如果通过路径安全检查，则返回一个空字符串
	# 如果安全检查失败，则返回对应的错误信息
	var security_error = validate_path_safety(path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	# 2. 扩展名检查
	# 调用BaseScriptTool基类方法进行安全检查
	var ext_error = validate_file_extension(path)
	if not ext_error.is_empty():
		return {"success": false, "data": ext_error}
	
	# 3. 文件存在性检查
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "Error: File not found: " + path + ". Please use 'create_script' tool first."}
	
	var res: Resource = load(path)
	if not res is Script:
		return {"success": false, "data": "Error: Resource at path is not a script."}
	
	var script = res as Script
	EditorInterface.edit_resource(script)
	
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var current_editor: ScriptEditorBase = script_editor.get_current_editor()
	
	if not current_editor:
		return {"success": false, "data": "Error: Could not access script editor."}
	
	var base_editor: Control = current_editor.get_base_editor()
	if not base_editor:
		return {"success": false, "data": "Error: Could not access text editor control."}
	
	# 4. 非空检查
	if base_editor.text.strip_edges().length() > 0:
		return {
			"success": false, 
			"data": "Error: Script is not empty; operation not allowed."
		}
	
	base_editor.text = content
	
	return {
		"success": true, 
		"data": "Successfully populated '" + path + "'. The file is now in an unsaved state (*)."
	}
