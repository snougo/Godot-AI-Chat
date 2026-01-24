@tool
extends BaseScriptTool

func _init() -> void:
	tool_name = "replace_script_code"
	tool_description = "Replacing old slice code with new code. Using `get_current_active_script` before replacing."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_name": {
				"type": "string",
				"description": "The name of the file (e.g., 'target_script.gd') to verify against the active script editor."
			},
			"original_code": {
				"type": "string",
				"description": "The EXACT code snippet to comment out. Must match the file content exactly."
			},
			"new_code": {
				"type": "string",
				"description": "The new code to insert immediately after the commented-out block."
			}
		},
		"required": ["file_name", "original_code", "new_code"]
	}


func execute(args: Dictionary) -> Dictionary:
	var target_file_name: String = args.get("file_name", "")
	var original_code: String = args.get("original_code", "")
	var new_code: String = args.get("new_code", "")
	
	if target_file_name.strip_edges().is_empty():
		return {"success": false, "data": "file_name cannot be empty."}
	
	if original_code.strip_edges().is_empty():
		return {"success": false, "data": "original_code cannot be empty."}

	# --- 1. 获取当前编辑器并校验 ---
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if not script_editor:
		return {"success": false, "data": "Script Editor not found."}
		
	var current_script: Script = script_editor.get_current_script()
	if not current_script:
		return {"success": false, "data": "No active script found. Using `open_script` to open target script."}
	
	var script_path: String = current_script.resource_path
	
	# [新增] 安全检查：路径黑名单 (来自 AiTool)
	var safety_error = validate_path_safety(script_path)
	if not safety_error.is_empty():
		return {"success": false, "data": safety_error}
	
	# [新增] 类型检查：扩展名白名单 (来自 BaseScriptTool)
	var ext_error = validate_file_extension(script_path)
	if not ext_error.is_empty():
		return {"success": false, "data": ext_error}
	
	var current_script_editor: ScriptEditorBase = script_editor.get_current_editor()
	if not current_script_editor:
		return {"success": false, "data": "No active script editor found."}
	
	var current_file_name: String = script_path.get_file()
	if current_file_name != target_file_name:
		return {
			"success": false, 
			"data": "Active script mismatch. Expected '%s', but found '%s'. Please open the correct file." % [target_file_name, current_file_name]
		}
	
	var code_editor: CodeEdit = current_script_editor.get_base_editor()
	
	# --- 2. 在全文中查找 original_code ---
	var total_lines: int = code_editor.get_line_count()
	var full_slice: Dictionary = {
		"start_line": 0,
		"end_line": total_lines - 1
	}
	
	var match_result: Dictionary = _find_code_in_slice(code_editor, full_slice, original_code)
	
	if not match_result.found:
		return {"success": false, "data": "Could not find 'original_code' in '%s'. Please ensure the code matches exactly." % target_file_name}
	
	var start_line = match_result.start_line
	var end_line = match_result.end_line
	
	# --- 3. 执行操作 ---
	if code_editor.has_method("begin_complex_operation"):
		code_editor.begin_complex_operation()
	
	# A. 获取缩进
	var indent = ""
	if start_line < code_editor.get_line_count():
		indent = _get_indentation(code_editor.get_line(start_line))

	# B. 注释旧代码
	for i in range(start_line, end_line + 1):
		var line_text = code_editor.get_line(i)
		if not line_text.strip_edges().is_empty() and not line_text.strip_edges().begins_with("#"):
			code_editor.set_line(i, "# " + line_text)
	
	# C. 插入新代码
	if not new_code.strip_edges().is_empty():
		if not new_code.ends_with("\n"):
			new_code += "\n"
		
		new_code = _apply_indentation(new_code, indent)
		code_editor.insert_text(new_code, end_line + 1, 0)
	
	if code_editor.has_method("end_complex_operation"):
		code_editor.end_complex_operation()
	
	return {
		"success": true, 
		"data": "Successfully commented out lines %d-%d and inserted new code in '%s'." % [start_line + 1, end_line + 1, target_file_name]
	}
