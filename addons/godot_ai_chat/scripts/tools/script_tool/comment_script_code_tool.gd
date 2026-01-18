@tool
extends BaseScriptTool

func _init() -> void:
	tool_name = "comment_script_code"
	tool_description = "Comments out code. REQUIRES 'slice_index' and exact code from 'get_current_active_script'."

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the script file."
			},
			"original_code": {
				"type": "string",
				"description": "The EXACT code snippet to disable. Must match the content within the target slice."
			},
			"slice_index": {
				"type": "integer",
				"description": "The 0-based index of the logical slice (e.g., function block) where the code resides."
			}
		},
		"required": ["path", "original_code", "slice_index"]
	}

func execute(args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path = args.get("path", "")
	var original_code = args.get("original_code", "")
	var slice_index = args.get("slice_index", -1)
	
	# --- 1. 安全与基本检查 ---
	var security_error = validate_path_safety(path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "File not found: " + path}
		
	if slice_index < 0:
		return {"success": false, "data": "Invalid slice_index. Must be >= 0."}
	
	if original_code.strip_edges().is_empty():
		return {"success": false, "data": "original_code cannot be empty."}

	# --- 2. 加载编辑器 ---
	var res = load(path)
	if not res is Script:
		return {"success": false, "data": "Resource is not a script."}
	
	EditorInterface.edit_resource(res)
	var script_editor = EditorInterface.get_script_editor()
	var current_editor = script_editor.get_current_editor()
	if not current_editor:
		return {"success": false, "data": "Could not access script editor."}
	var base_editor = current_editor.get_base_editor()
	
	# --- 3. 获取所有切片 (基类) ---
	var current_text = base_editor.text
	var slices = _parse_script_to_slices(current_text)
	
	if slice_index >= slices.size():
		return {"success": false, "data": "slice_index %d out of bounds. Total slices: %d" % [slice_index, slices.size()]}
	
	var target_slice = slices[slice_index]
	
	# --- 4. 在切片内匹配原始代码 (基类) ---
	var match_result = _find_code_in_slice(base_editor, target_slice, original_code)
	
	if not match_result.found:
		var msg = "Could not find 'original_code' in slice %d (Lines %d-%d).\n" % [slice_index, target_slice.start_line + 1, target_slice.end_line + 1]
		msg += "Slice Context (First 5 lines):\n%s\n...\n" % _get_preview_lines(base_editor, target_slice, 5)
		msg += "ACTION: Verify 'slice_index' and ensure 'original_code' exactly matches the file content."
		return {"success": false, "data": msg}
	
	# --- 5. 执行注释操作 ---
	var start_line = match_result.start_line
	var end_line = match_result.end_line
	
	if base_editor.has_method("begin_complex_operation"):
		base_editor.begin_complex_operation()
	
	for i in range(start_line, end_line + 1):
		var line_text = base_editor.get_line(i)
		# 仅注释非空且未被注释的行
		if not line_text.strip_edges().is_empty() and not line_text.strip_edges().begins_with("#"):
			base_editor.set_line(i, "# " + line_text)
	
	if base_editor.has_method("end_complex_operation"):
		base_editor.end_complex_operation()
		
	return {
		"success": true, 
		"data": "Successfully commented out code in slice %d (Lines %d-%d). Verify the change in the editor." % [slice_index, start_line + 1, end_line + 1]
	}
