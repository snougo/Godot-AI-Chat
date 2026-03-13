@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "delete_script_slice"
	tool_description = "Deletes a specific logic slice (function, variable, etc.) from the active Script Editor."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"target_signature": { 
				"type": "string", 
				"description": "The signature of the target slice (e.g. 'func target_signature():' or 'var/const/signal/@onready/@export target_signature')." 
			}
		},
		"required": ["target_signature"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var signature: String = p_args.get("target_signature", "")
	
	var code_edit := _get_code_edit("")
	if not code_edit: return {"success": false, "data": "No active script editor."}
	
	# 1. 查找依赖引用
	var references := find_references(code_edit.text, signature)
	var references_warning := ""
	if references.size() > 0:
		references_warning = "\n⚠️ WARNING: Found %d reference(s) to this slice:\n" % references.size()
		for ref in references:
			references_warning += "\nLine %d (%s):\n%s\n" % [ref.line, ref.type, ref.context]
		references_warning += "\nPlease manually update these references after deletion!"
	
	# 2. 查找目标切片
	var match_result := find_best_match_slice(code_edit, signature)
	if not match_result.found:
		return {"success": false, "data": "Could not find a slice matching: '%s'. Please check the slices view." % signature}
	
	var target_slice: Dictionary = match_result.slice
	var slices: Array = parse_script_to_slices(code_edit.text)
	
	# 3. 查找孤立的注释切片（在目标切片之后，下一个逻辑切片之前）
	var orphaned_comments := []
	var target_index := -1
	
	# 找到目标切片的索引
	for i in range(slices.size()):
		if slices[i] == target_slice:
			target_index = i
			break
	
	if target_index != -1:
		# 向后查找孤立的 COMMENT 切片
		var i := target_index + 1
		while i < slices.size():
			var check_slice = slices[i]
			
			# 遇到 GAP，继续检查
			if check_slice.type == "GAP":
				i += 1
				continue
			
			# 遇到 COMMENT，记录为孤立注释
			if check_slice.type == "COMMENT":
				orphaned_comments.append(check_slice)
				i += 1
				continue
			
			# 遇到其他逻辑切片，停止
			break
	
	# 4. 执行删除（从后往前删除，避免行号变化）
	# 先删除孤立注释
	for comment_slice in orphaned_comments:
		code_edit.select(comment_slice.start_line, 0, comment_slice.end_line, code_edit.get_line(comment_slice.end_line).length())
		code_edit.insert_text_at_caret("")
	
	# 再删除目标切片
	code_edit.select(target_slice.start_line, 0, target_slice.end_line, code_edit.get_line(target_slice.end_line).length())
	code_edit.insert_text_at_caret("")
	code_edit.deselect()
	
	# 5. 生成返回结果
	var view := get_sliced_code_view(code_edit)
	var result_data := "Deleted slice matching '%s'." % signature
	
	if references.size() > 0:
		result_data += references_warning
	
	result_data += "\n\nCurrent Structure:\n%s" % view
	
	return {"success": true, "data": result_data, "references": references}
