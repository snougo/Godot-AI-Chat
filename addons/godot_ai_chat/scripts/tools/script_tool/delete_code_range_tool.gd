@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "delete_code_range"
	tool_description = "Deletes code from the active Script Editor by line range (1-based)."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"start_line": { 
				"type": "integer", 
				"description": "The starting line number (1-based, inclusive) to delete from." 
			},
			"end_line": { 
				"type": "integer", 
				"description": "The ending line number (1-based, inclusive) to delete to." 
			}
		},
		"required": ["start_line", "end_line"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var start_line: int = p_args.get("start_line", 0)
	var end_line: int = p_args.get("end_line", 0)
	
	var code_edit := _get_code_edit("")
	if not code_edit: 
		return {"success": false, "data": "No active script editor."}
	
	var total_lines := code_edit.get_line_count()
	
	# 行号范围校验（1-based）
	if start_line < 1 or end_line < 1 or start_line > total_lines or end_line > total_lines:
		return {
			"success": false, 
			"data": "Line numbers out of bounds. Valid range: 1-%d, got start_line=%d, end_line=%d" % [total_lines, start_line, end_line]
		}
	
	if start_line > end_line:
		return {
			"success": false, 
			"data": "Invalid range: start_line (%d) cannot be greater than end_line (%d)." % [start_line, end_line]
		}
	
	# 转换为 0-based 索引
	var start_idx := start_line - 1
	var end_idx := end_line - 1
	
	# 执行删除
	var end_column := code_edit.get_line(end_idx).length()
	code_edit.select(start_idx, 0, end_idx, end_column)
	code_edit.insert_text_at_caret("")
	code_edit.deselect()
	
	# 使用父类方法返回带行号的完整脚本内容
	var view := get_full_script_with_line_numbers(code_edit)
	return {
		"success": true, 
		"data": "Deleted lines %d-%d.\n\nCurrent Script:\n%s" % [start_line, end_line, view]
	}
