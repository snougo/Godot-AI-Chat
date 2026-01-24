@tool
extends BaseScriptTool

func _init() -> void:
	tool_name = "insert_script_code"
	tool_description = "Inserts new code at a specific line number. Using `get_current_active_script` before inserting."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_name": {
				"type": "string",
				"description": "The name of the file (e.g., 'my_script.gd') to verify against the active script editor."
			},
			"new_code": {
				"type": "string",
				"description": "The new gdscript code to insert."
			},
			"insert_position": {
				"type": "integer",
				"description": "The 1-based line number where the code should be inserted."
			}
		},
		"required": ["file_name", "new_code", "insert_position"]
	}


func execute(args: Dictionary) -> Dictionary:
	var target_file_name: String = args.get("file_name", "")
	var new_code: String = args.get("new_code", "")
	var insert_line_num: int = args.get("insert_position", -1) # 1-based
	
	if target_file_name.strip_edges().is_empty():
		return {"success": false, "data": "file_name cannot be empty."}
	
	if insert_line_num < 1:
		return {"success": false, "data": "insert_position must be a line number >= 1."}
	
	var line_index: int = insert_line_num - 1

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
	
	var current_file_name: String = script_path.get_file()
	if current_file_name != target_file_name:
		return {
			"success": false, 
			"data": "Active script mismatch. Expected '%s', but found '%s'. Please open the correct file." % [target_file_name, current_file_name]
		}
	
	var current_script_editor = script_editor.get_current_editor()
	if not current_script_editor:
		return {"success": false, "data": "No active script editor found."}
	
	var code_editor: CodeEdit = current_script_editor.get_base_editor()
	var total_lines: int = code_editor.get_line_count()
	
	if line_index > total_lines:
		return {"success": false, "data": "insert_position %d is out of bounds. Max lines: %d" % [insert_line_num, total_lines]}
	
	# --- 2. 执行插入 ---
	if code_editor.has_method("begin_complex_operation"):
		code_editor.begin_complex_operation()
	
	if not new_code.ends_with("\n"):
		new_code += "\n"
	
	# 智能缩进
	var indent_ref_line: int = line_index
	if indent_ref_line >= total_lines:
		indent_ref_line = total_lines - 1
	elif indent_ref_line > 0:
		indent_ref_line -= 1
	
	var indent := ""
	if indent_ref_line >= 0 and indent_ref_line < total_lines:
		indent = _get_indentation(code_editor.get_line(indent_ref_line))
	
	new_code = _apply_indentation(new_code, indent)
	
	code_editor.insert_text(new_code, line_index, 0)
	
	if code_editor.has_method("end_complex_operation"):
		code_editor.end_complex_operation()
	
	return {
		"success": true, 
		"data": "Successfully inserted code at line %d in '%s'." % [insert_line_num, target_file_name]
	}
