@tool
extends BaseScriptTool

## 在指定位置插入新代码。
## 支持行号和锚点文本定位。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "insert_script_code"
	tool_description = "Inserts new code at a specific position. Using `get_current_active_script` before inserting"


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
			"new_code": {
				"type": "string",
				"description": "The new gdscript code to insert."
			},
			"insert_position": {
				"type": "integer",
				"description": "[Optional] The 1-based line number. Used ONLY if anchor_text is not provided."
			},
			"anchor_text": {
				"type": "string",
				"description": "[Optional] Unique text to find in the file to determine the insertion point (e.g. 'func _ready():'). Preferred over line numbers."
			},
			"offset": {
				"type": "string",
				"enum": ["before", "after"],
				"description": "[Optional] 'before' or 'after' the anchor_text/line. Defaults to 'after'."
			}
		},
		"required": ["file_name", "new_code"]
	}


## 执行插入代码操作
## [param p_args]: 包含 file_name、new_code 等的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var target_file_name: String = p_args.get("file_name", "")
	var new_code: String = p_args.get("new_code", "")
	var insert_line_num: int = p_args.get("insert_position", -1)
	var anchor_text: String = p_args.get("anchor_text", "")
	var offset: String = p_args.get("offset", "after")
	
	if target_file_name.strip_edges().is_empty():
		return {"success": false, "data": "file_name cannot be empty."}
	
	var editor_result: Dictionary = _get_and_validate_editor(target_file_name)
	if not editor_result.get("success", false):
		return editor_result
	
	var code_editor: CodeEdit = editor_result.code_editor
	
	var position_result: Dictionary = _determine_insert_position(code_editor, anchor_text, insert_line_num, offset)
	if not position_result.get("success", false):
		return position_result
	
	var target_line_index: int = position_result.target_line_index
	var method_used: String = position_result.method_used
	
	_perform_insertion(code_editor, new_code, target_line_index, anchor_text, offset)
	
	var snapshot: String = get_code_snapshot(code_editor, target_line_index, 6)
	
	return {"success": true, "data": "Successfully inserted code using %s.\n%s" % [method_used, snapshot]}


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
	
	var current_script_editor = script_editor.get_current_editor()
	if not current_script_editor:
		return {"success": false, "data": "No active script editor found."}
	
	return {"success": true, "code_editor": current_script_editor.get_base_editor()}


## 确定插入位置
## [param p_code_editor]: 代码编辑器
## [param p_anchor_text]: 锚点文本
## [param p_insert_line_num]: 插入行号
## [param p_offset]: 偏移量
## [return]: 包含 target_line_index 和 method_used 的字典
func _determine_insert_position(p_code_editor: CodeEdit, p_anchor_text: String, p_insert_line_num: int, p_offset: String) -> Dictionary:
	var target_line_index: int = -1
	var method_used := ""
	var total_lines: int = p_code_editor.get_line_count()
	
	if not p_anchor_text.is_empty():
		method_used = "anchor_text ('%s')" % p_anchor_text
		var full_slice := {"start_line": 0, "end_line": total_lines - 1}
		var match_result: Dictionary = find_code_in_slice(p_code_editor, full_slice, p_anchor_text)
		
		if match_result.found:
			if p_offset == "before":
				target_line_index = match_result.start_line
			else:
				target_line_index = match_result.end_line + 1
		else:
			return {"success": false, "data": "Could not find anchor_text: '%s'." % p_anchor_text}
	
	elif p_insert_line_num >= 1:
		method_used = "line number (%d)" % p_insert_line_num
		if p_insert_line_num > total_lines + 1:
			return {"success": false, "data": "insert_position %d is out of bounds (max %d)." % [p_insert_line_num, total_lines]}
		
		var base_index: int = p_insert_line_num - 1
		if p_offset == "after":
			target_line_index = base_index + 1
		else:
			target_line_index = base_index
	else:
		return {"success": false, "data": "Must provide either 'anchor_text' or valid 'insert_position'."}
	
	return {"success": true, "target_line_index": target_line_index, "method_used": method_used}


## 执行插入操作
## [param p_code_editor]: 代码编辑器
## [param p_new_code]: 新代码
## [param p_target_line_index]: 目标行索引
## [param p_anchor_text]: 锚点文本
## [param p_offset]: 偏移量
func _perform_insertion(p_code_editor: CodeEdit, p_new_code: String, p_target_line_index: int, p_anchor_text: String, p_offset: String) -> void:
	if p_code_editor.has_method("begin_complex_operation"):
		p_code_editor.begin_complex_operation()
	
	if not p_new_code.ends_with("\n"):
		p_new_code += "\n"
	
	var indent_ref_line: int = _get_indent_reference_line(p_code_editor, p_target_line_index, p_anchor_text, p_offset)
	var indent: String = _calculate_indent(p_code_editor, indent_ref_line, p_anchor_text, p_offset)
	
	p_new_code = apply_indentation(p_new_code, indent)
	
	p_code_editor.insert_text(p_new_code, p_target_line_index, 0)
	
	if p_code_editor.has_method("end_complex_operation"):
		p_code_editor.end_complex_operation()


## 获取缩进参考行
## [param p_code_editor]: 代码编辑器
## [param p_target_line_index]: 目标行索引
## [param p_anchor_text]: 锚点文本
## [param p_offset]: 偏移量
## [return]: 参考行号
func _get_indent_reference_line(p_code_editor: CodeEdit, p_target_line_index: int, p_anchor_text: String, p_offset: String) -> int:
	var indent_ref_line: int = p_target_line_index
	
	if indent_ref_line >= p_code_editor.get_line_count():
		indent_ref_line = p_code_editor.get_line_count() - 1
	elif indent_ref_line > 0 and p_offset == "after":
		indent_ref_line = indent_ref_line - 1
	
	return indent_ref_line


## 计算缩进
## [param p_code_editor]: 代码编辑器
## [param p_indent_ref_line]: 缩进参考行
## [param p_anchor_text]: 锚点文本
## [param p_offset]: 偏移量
## [return]: 缩进字符串
func _calculate_indent(p_code_editor: CodeEdit, p_indent_ref_line: int, p_anchor_text: String, p_offset: String) -> String:
	var indent := ""
	
	if p_indent_ref_line >= 0 and p_indent_ref_line < p_code_editor.get_line_count():
		indent = get_indentation(p_code_editor.get_line(p_indent_ref_line))
		
		if not p_anchor_text.is_empty() and p_offset == "after":
			var anchor_line: String = p_code_editor.get_line(p_indent_ref_line).strip_edges()
			if anchor_line.ends_with(":"):
				indent += "\t"
	
	return indent
