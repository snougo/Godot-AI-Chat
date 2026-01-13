@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "insert_script_code"
	tool_description = "Inserts new code at a specific line. 1. INSERT: Use 'insert_after_line' and 'new_code'. 2. READ: Use 'read_from_line' to inspect context before inserting."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the script file."
			},
			"new_code": {
				"type": "string",
				"description": "The GDScript code to insert. Required for INSERT mode."
			},
			"insert_after_line": {
				"type": "integer",
				"description": "The 1-based line number AFTER which the new code will be inserted. Use 0 to insert at the very beginning of the file."
			},
			"read_from_line": {
				"type": "integer",
				"description": "Start reading from this line. Returns a logical code block to help you decide where to insert."
			}
		},
		"required": ["path"]
	}


func execute(args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path = args.get("path", "")
	var new_code = args.get("new_code", null)
	var insert_after_line = args.get("insert_after_line", -1)
	var read_from_line = args.get("read_from_line", -1)
	
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
	
	# INSERT 模式
	if new_code != null and insert_after_line >= 0:
		return _handle_insertion(base_editor, int(insert_after_line), new_code)
	
	# READ 模式 (默认行为或显式调用)
	else:
		# 如果没传 read_from_line，默认为 1
		var start_read = 1
		if read_from_line > 0:
			start_read = read_from_line
			
		return _handle_reading(base_editor, start_read, total_lines)


# --- 处理插入逻辑 ---
func _handle_insertion(editor: Control, insert_after_line: int, new_code: String) -> Dictionary:
	var total = editor.get_line_count()
	
	# 范围检查 (允许 insert_after_line = 0，表示插在开头)
	if insert_after_line > total:
		return {
			"success": false, 
			"data": "Error: 'insert_after_line' (%d) exceeds file length (%d)." % [insert_after_line, total]
		}
	
	# 确保新代码末尾有换行，保持格式整洁
	if not new_code.ends_with("\n"):
		new_code += "\n"
	
	if editor.has_method("begin_complex_operation"):
		editor.begin_complex_operation()
	
	# insert_text 的第二个参数是行号 (0-based)
	# 如果 insert_after_line 是 5，意味着插在第 5 行之后，即第 6 行的位置 (index 5)
	# 如果 insert_after_line 是 0，意味着插在第 0 行之前，即 index 0
	var insert_pos_index = insert_after_line
	
	editor.insert_text(new_code, insert_pos_index, 0)
	
	if editor.has_method("end_complex_operation"):
		editor.end_complex_operation()
		
	return {"success": true, "data": "Successfully inserted code after line %d." % insert_after_line}


# --- 处理阅读逻辑 (复用 replace 工具的智能切片算法) ---
func _handle_reading(editor: Control, read_from_line: int, total_lines: int) -> Dictionary:
	var start_idx = read_from_line - 1
	if start_idx < 0: start_idx = 0
	
	if start_idx >= total_lines:
		return {"success": false, "data": "End of file reached. Total lines: %d" % total_lines}
		
	var slice_data = _get_logical_block_slice(editor, start_idx, total_lines)
	
	var msg = "Reading script context for insertion.\n"
	msg += "--------------------------------------------------\n"
	msg += slice_data["text"]
	msg += "--------------------------------------------------\n"
	msg += "ACTION: Call again with 'insert_after_line' and 'new_code' to insert.\n"
	
	if slice_data["next_line"] <= total_lines:
		msg += "To READ MORE: Call with 'read_from_line=%d'." % slice_data["next_line"]
	else:
		msg += "End of file reached."
	
	return {"success": false, "data": msg}


# --- 辅助算法：智能切片 (逻辑块) ---
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
	
	return {
		"text": result_text,
		"next_line": current_line + 1
	}
