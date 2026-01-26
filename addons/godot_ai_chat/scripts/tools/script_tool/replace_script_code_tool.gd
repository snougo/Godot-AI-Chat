@tool
class_name ReplaceScriptCodeTool
extends BaseScriptTool

## 用新代码替换旧的切片代码。
## 精确匹配 'original_code'。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "replace_script_code"
	tool_description = "Replacing old slice code with new code. Using `get_current_active_script` before replacing."

# --- Public Functions ---

## 获取工具参数的 JSON Schema
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
				"description": "The EXACT code snippet to comment out/replace."
			},
			"new_code": {
				"type": "string",
				"description": "The new code to insert."
			}
		},
		"required": ["file_name", "original_code", "new_code"]
	}


## 执行替换代码操作
## [param p_args]: 包含 file_name、original_code 和 new_code 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var target_file_name: String = p_args.get("file_name", "")
	var original_code: String = p_args.get("original_code", "")
	var new_code: String = p_args.get("new_code", "")
	
	if target_file_name.strip_edges().is_empty():
		return {"success": false, "data": "file_name cannot be empty."}
	
	if original_code.strip_edges().is_empty():
		return {"success": false, "data": "original_code cannot be empty."}
	
	var editor_result: Dictionary = _get_and_validate_editor(target_file_name)
	if not editor_result.get("success", false):
		return editor_result
	
	var code_editor: CodeEdit = editor_result.code_editor
	
	var match_result: Dictionary = _find_original_code(code_editor, original_code)
	if not match_result.get("success", false):
		return match_result
	
	var start_line: int = match_result.start_line
	var end_line: int = match_result.end_line
	
	_perform_replacement(code_editor, start_line, end_line, new_code)
	
	var snapshot: String = get_code_snapshot(code_editor, end_line + 1, 6)
	
	return {"success": true, "data": "Successfully commented out lines %d-%d and inserted new code in '%s'.\n%s" % [start_line + 1, end_line + 1, target_file_name, snapshot]}


# --- Private Functions ---

## 获取并验证编辑器
## [param p_target_file_name]: 目标文件名
## [return]: 包含 code_editor 的字典
func _get_and_validate_editor(p_target_file_name: String) -> Dictionary:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if not script_editor:
		return {"success": false, "data": "Script Editor not found."}
	
	var current_script: Script = script_editor.get_current_script()
	if not current_script:
		return {"success": false, "data": "No active script found. Using `open_script` to open target script."}
	
	var script_path: String = current_script.resource_path
	
	var safety_error: String = validate_path_safety(script_path)
	if not safety_error.is_empty():
		return {"success": false, "data": safety_error}
	
	var ext_error: String = validate_file_extension(script_path)
	if not ext_error.is_empty():
		return {"success": false, "data": ext_error}
	
	var current_file_name: String = script_path.get_file()
	if current_file_name != p_target_file_name:
		return {
			"success": false, 
			"data": "Active script mismatch. Expected '%s', but found '%s'. Please open the correct file." % [p_target_file_name, current_file_name]
		}
	
	var current_script_editor: ScriptEditorBase = script_editor.get_current_editor()
	if not current_script_editor:
		return {"success": false, "data": "No active script editor found."}
	
	return {"success": true, "code_editor": current_script_editor.get_base_editor()}


## 查找原始代码
## [param p_code_editor]: 代码编辑器
## [param p_original_code]: 原始代码
## [return]: 包含 start_line 和 end_line 的字典
func _find_original_code(p_code_editor: CodeEdit, p_original_code: String) -> Dictionary:
	var total_lines: int = p_code_editor.get_line_count()
	var full_slice: Dictionary = {"start_line": 0, "end_line": total_lines - 1}
	
	var match_result: Dictionary = find_code_in_slice(p_code_editor, full_slice, p_original_code)
	
	if not match_result.found:
		return {"success": false, "data": "Could not find 'original_code'. Please ensure the code matches exactly."}
	
	return {"success": true, "start_line": match_result.start_line, "end_line": match_result.end_line}


## 执行替换操作
## [param p_code_editor]: 代码编辑器
## [param p_start_line]: 起始行
## [param p_end_line]: 结束行
## [param p_new_code]: 新代码
func _perform_replacement(p_code_editor: CodeEdit, p_start_line: int, p_end_line: int, p_new_code: String) -> void:
	if p_code_editor.has_method("begin_complex_operation"):
		p_code_editor.begin_complex_operation()
	
	var indent: String = get_indentation(p_code_editor.get_line(p_start_line))
	
	_comment_out_old_code(p_code_editor, p_start_line, p_end_line)
	_insert_new_code(p_code_editor, p_end_line, p_new_code, indent)
	
	if p_code_editor.has_method("end_complex_operation"):
		p_code_editor.end_complex_operation()


## 注释旧代码
## [param p_code_editor]: 代码编辑器
## [param p_start_line]: 起始行
## [param p_end_line]: 结束行
func _comment_out_old_code(p_code_editor: CodeEdit, p_start_line: int, p_end_line: int) -> void:
	for i in range(p_start_line, p_end_line + 1):
		var line_text: String = p_code_editor.get_line(i)
		if not line_text.strip_edges().is_empty() and not line_text.strip_edges().begins_with("#"):
			p_code_editor.set_line(i, "# " + line_text)


## 插入新代码
## [param p_code_editor]: 代码编辑器
## [param p_end_line]: 结束行
## [param p_new_code]: 新代码
## [param p_indent]: 缩进
func _insert_new_code(p_code_editor: CodeEdit, p_end_line: int, p_new_code: String, p_indent: String) -> void:
	var insert_line: int = p_end_line + 1
	
	if not p_new_code.strip_edges().is_empty():
		if not p_new_code.ends_with("\n"):
			p_new_code += "\n"
		
		p_new_code = apply_indentation(p_new_code, p_indent)
		p_code_editor.insert_text(p_new_code, insert_line, 0)
