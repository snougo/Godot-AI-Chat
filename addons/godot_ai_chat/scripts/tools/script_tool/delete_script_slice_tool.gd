@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "delete_script_slice"
	tool_description = "Delete a specific logic slice (function, variable, etc.) from the active script, leaving an empty line."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"target_signature": { 
				"type": "string", 
				"description": "The signature line of the slice to delete (e.g. 'func _ready():' or 'var speed = 10')." 
			}
		},
		"required": ["target_signature"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var signature: String = p_args.get("target_signature", "")
	
	var code_edit := _get_code_edit("") # Get active editor
	if not code_edit: return {"success": false, "data": "No active script editor."}
	
	var match_result := find_best_match_slice(code_edit, signature)
	if not match_result.found:
		return {"success": false, "data": "Could not find a slice matching: '%s'. Please check the slices view." % signature}
	
	var slice: Dictionary = match_result.slice
	
	# 选中切片范围（包括前置空行/注释）并替换为空字符串
	# CodeEdit 的行为是：如果多行被选中且替换为不含换行符的内容，这些行会合并为一行
	# 因此替换为 "" 会导致原切片占据的多行空间缩减为一行空行
	code_edit.select(slice.start_line, 0, slice.end_line, code_edit.get_line(slice.end_line).length())
	code_edit.insert_text_at_caret("")
	code_edit.deselect()
	
	var view := get_sliced_code_view(code_edit)
	return {"success": true, "data": "Deleted slice matching '%s'.\n\nCurrent Structure:\n%s" % [signature, view]}
