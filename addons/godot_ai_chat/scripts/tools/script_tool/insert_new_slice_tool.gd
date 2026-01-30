@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "insert_new_slice"
	tool_description = "Insert a new code slice (function, var, etc.) at a specific line."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"target_line": { 
				"type": "integer", 
				"description": "The line number (1-based) to insert at. Must be an empty line." 
			},
			"new_content": { "type": "string", "description": "Code to insert." }
		},
		"required": ["target_line", "new_content"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var line_arg: int = p_args.get("target_line", 0)
	var content: String = p_args.get("new_content", "")
	
	var code_edit := _get_code_edit("")
	if not code_edit: return {"success": false, "data": "No active script editor."}
	
	var total_lines := code_edit.get_line_count()
	var insert_idx := line_arg - 1
	
	# 校验
	if insert_idx < 0 or insert_idx > total_lines:
		return {"success": false, "data": "Line number out of bounds."}
		
	if insert_idx < total_lines:
		var line_content := code_edit.get_line(insert_idx).strip_edges()
		if not line_content.is_empty():
			return {"success": false, "data": "Target line %d is not empty. Please insert at an empty line." % line_arg}
	
	# 格式化插入：确保上下有空行
	var final_content := content
	if insert_idx > 0:
		if not code_edit.get_line(insert_idx - 1).strip_edges().is_empty():
			final_content = "\n" + final_content
	if insert_idx < total_lines - 1:
		if not code_edit.get_line(insert_idx + 1).strip_edges().is_empty():
			final_content = final_content + "\n"
	
	code_edit.set_caret_line(insert_idx)
	code_edit.set_caret_column(0)
	code_edit.insert_text_at_caret(final_content)
	
	var view := get_sliced_code_view(code_edit)
	return {"success": true, "data": "Inserted at line %d.\n\nCurrent Structure:\n%s" % [line_arg, view]}
