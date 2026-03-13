@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "insert_code"
	tool_description = "Inserts new code at a specific line. The content is inserted exactly as provided - control spacing manually in new_content."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"target_line": { 
				"type": "integer", 
				"description": "The line number (1-based) to insert at. Must be an empty line." 
			},
			"new_content": { 
				"type": "string", 
				"description": "Code to insert. Include any leading/trailing newlines explicitly if spacing is needed." 
			}
		},
		"required": ["target_line", "new_content"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var line_arg: int = p_args.get("target_line", 0)
	var content: String = p_args.get("new_content", "")
	
	var code_edit := _get_code_edit("")
	if not code_edit: 
		return {"success": false, "data": "No active script editor."}
	
	var total_lines := code_edit.get_line_count()
	var insert_idx := line_arg - 1
	
	# 行号范围校验
	if insert_idx < 0 or insert_idx > total_lines:
		return {"success": false, "data": "Line number out of bounds. Valid range: 1-%d" % total_lines}
	
	# 检查目标行是否为空（允许在文件末尾插入）
	if insert_idx < total_lines:
		var line_content := code_edit.get_line(insert_idx).strip_edges()
		if not line_content.is_empty():
			return {
				"success": false, 
				"data": "Target line %d is not empty. Please insert at an empty line.\nCurrent content: '%s'" % [line_arg, line_content]
			}
	
	# 精确插入：不自动添加任何空行，完全由 new_content 控制
	code_edit.set_caret_line(insert_idx)
	code_edit.set_caret_column(0)
	code_edit.insert_text_at_caret(content)
	
	# 使用父类方法返回带行号的完整脚本内容
	var view := get_full_script_with_line_numbers(code_edit)
	return {
		"success": true, 
		"data": "Inserted at line %d.\n\nCurrent Script:\n%s" % [line_arg, view]
	}
