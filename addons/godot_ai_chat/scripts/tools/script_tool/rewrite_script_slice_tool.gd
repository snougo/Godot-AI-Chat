@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "rewrite_script_slice"
	tool_description = "Rewrite a specific logic slice (function, variable, etc.) in the active script."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"target_signature": { 
				"type": "string", 
				"description": "The signature line of the slice to replace (e.g. 'func _ready():' or 'var speed = 10')." 
			},
			"new_content": { 
				"type": "string", 
				"description": "The complete new code for this slice." 
			}
		},
		"required": ["target_signature", "new_content"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var signature: String = p_args.get("target_signature", "")
	var new_content: String = p_args.get("new_content", "")
	
	var code_edit := _get_code_edit("") # Get active
	if not code_edit: return {"success": false, "data": "No active script editor."}
	
	var match_result := find_best_match_slice(code_edit, signature)
	if not match_result.found:
		return {"success": false, "data": "Could not find a slice matching: '%s'. Please check the slices view." % signature}
	
	var slice: Dictionary = match_result.slice
	
	# 执行替换
	code_edit.select(slice.start_line, 0, slice.end_line, code_edit.get_line(slice.end_line).length())
	code_edit.insert_text_at_caret(new_content)
	code_edit.deselect()
	
	var view := get_sliced_code_view(code_edit)
	return {"success": true, "data": "Rewrote slice matching '%s'.\n\nCurrent Structure:\n%s" % [signature, view]}
