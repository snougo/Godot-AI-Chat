@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "disable_script_code"
	tool_description = "Safely comments out a block of code. REQUIRES 'start_line', 'end_line', and 'original_code' for verification. Use this BEFORE inserting new code."


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
				"description": "The EXACT code currently at start_line/end_line. Required to verify we are disabling the correct lines."
			},
			"start_line": {
				"type": "integer",
				"description": "The 1-based start line number to disable."
			},
			"end_line": {
				"type": "integer",
				"description": "The 1-based end line number to disable."
			},
			"read_from_line": {
				"type": "integer",
				"description": "Start reading from this line. Returns a logical code block. Use this if verification fails."
			}
		},
		"required": ["path"]
	}


func execute(args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path = args.get("path", "")
	var original_code = args.get("original_code", null)
	var start_line = args.get("start_line", -1)
	var end_line = args.get("end_line", -1)
	var read_from_line = args.get("read_from_line", 1)
	
	# --- 1. 安全与基本检查 ---
	var security_error = validate_path_safety(path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	var ext_error = validate_file_extension(path)
	if not ext_error.is_empty():
		return {"success": false, "data": ext_error}
	
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "File not found: " + path}
	
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
	var total_lines = base_editor.get_line_count()
	
	# --- 3. 确定操作模式 ---
	
	# 只有当提供了完整的校验参数时，才执行修改
	if start_line > 0 and end_line > 0 and original_code != null:
		return _handle_disable(base_editor, int(start_line), int(end_line), original_code)
	
	# 否则进入阅读模式，帮助模型定位
	else:
		return _handle_reading(base_editor, int(read_from_line), total_lines)


# --- 核心逻辑：注释代码 ---
func _handle_disable(editor: Control, start_line: int, end_line: int, original_code: String) -> Dictionary:
	var start_idx = start_line - 1
	var end_idx = end_line - 1
	var total = editor.get_line_count()
	
	# 1. 范围检查
	if start_idx < 0 or end_idx >= total or start_idx > end_idx:
		return {
			"success": false, 
			"data": "Error: Invalid line range %d-%d. File has %d lines." % [start_line, end_line, total]
		}
	
	# 2. 提取并校验
	var actual_lines = []
	var actual_code_str = ""
	for i in range(start_idx, end_idx + 1):
		var line = editor.get_line(i)
		actual_lines.append(line)
		actual_code_str += "%4d | %s\n" % [i + 1, line]
	
	if not _verify_code_match(actual_lines, original_code):
		var msg = "Verification Failed! Code mismatch at lines %d-%d.\n" % [start_line, end_line]
		msg += "Expected (Your Input):\n%s\n" % original_code
		msg += "Actual (In File):\n%s\n" % actual_code_str
		msg += "ACTION: Please inspect the actual code above and retry with the correct 'original_code' or lines."
		return {"success": false, "data": msg}
	
	# 3. 执行注释
	if editor.has_method("begin_complex_operation"):
		editor.begin_complex_operation()
	
	for i in range(start_idx, end_idx + 1):
		var line_text = editor.get_line(i)
		# 仅注释非空且未被注释的行
		if not line_text.strip_edges().is_empty() and not line_text.strip_edges().begins_with("#"):
			editor.set_line(i, "# " + line_text)
	
	if editor.has_method("end_complex_operation"):
		editor.end_complex_operation()
	
	# 4. 返回下一步指引
	# 提示模型在被注释的代码块之前或之后插入
	var insert_hint_before = start_line - 1 # 插在被注释块的上方
	var insert_hint_after = end_line        # 插在被注释块的下方
	
	return {
		"success": true, 
		"data": "Successfully commented out lines %d-%d. To replace this logic, use 'insert_script_code' with 'insert_after_line=%d' (before) or '%d' (after)." % [start_line, end_line, insert_hint_before, insert_hint_after]
	}


# --- 阅读模式 (复用标准逻辑) ---
func _handle_reading(editor: Control, read_from_line: int, total_lines: int) -> Dictionary:
	var start_idx = read_from_line - 1
	if start_idx < 0: start_idx = 0
	if start_idx >= total_lines:
		return {"success": false, "data": "End of file reached. Total lines: %d" % total_lines}
		
	var slice_data = _get_logical_block_slice(editor, start_idx, total_lines)
	
	var msg = "Reading script context (Disable Mode).\n"
	msg += "--------------------------------------------------\n"
	msg += slice_data["text"]
	msg += "--------------------------------------------------\n"
	msg += "ACTION: To DISABLE code, call again with 'start_line', 'end_line', and 'original_code'.\n"
	
	if slice_data["next_line"] <= total_lines:
		msg += "To READ MORE: Call with 'read_from_line=%d'." % slice_data["next_line"]
	
	return {"success": false, "data": msg}


# --- 辅助算法 ---
func _verify_code_match(actual_lines: Array, original_code_str: String) -> bool:
	var actual_clean = []
	for line in actual_lines:
		var s = line.strip_edges()
		if not s.is_empty():
			actual_clean.append(s)
	
	var original_clean = []
	var original_split = original_code_str.split("\n")
	for line in original_split:
		var s = line.strip_edges()
		if not s.is_empty():
			original_clean.append(s)
	
	if actual_clean.size() != original_clean.size():
		return false
	for i in range(actual_clean.size()):
		if actual_clean[i] != original_clean[i]:
			return false
	return true


func _get_logical_block_slice(editor: Control, from_line: int, total_lines: int) -> Dictionary:
	var result_text = ""
	var current_line = from_line
	var block_content_started = false
	while current_line < total_lines:
		var line_content = editor.get_line(current_line)
		var is_top_level_func = line_content.begins_with("func ") 
		if is_top_level_func and block_content_started:
			break
		if not line_content.strip_edges().is_empty() and not line_content.strip_edges().begins_with("#"):
			block_content_started = true
		result_text += "%4d | %s\n" % [current_line + 1, line_content]
		current_line += 1
	return {"text": result_text, "next_line": current_line + 1}
