@tool
extends BaseScriptTool

func _init() -> void:
	tool_name = "insert_script_code"
	tool_description = "Inserts code into a slice. REQUIRES 'slice_index' from 'get_current_active_script'."

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
				"description": "The GDScript code to insert."
			},
			"slice_index": {
				"type": "integer",
				"description": "The 0-based index of the logical slice (e.g., function block) to search in."
			},
			"anchor_code": {
				"type": "string",
				"description": "The EXACT code snippet in the slice to use as a reference point."
			},
			"insert_position": {
				"type": "string",
				"enum": ["after", "before"],
				"description": "Insert 'after' (default) or 'before' the anchor code."
			}
		},
		"required": ["path", "new_code", "slice_index", "anchor_code"]
	}

func execute(args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path = args.get("path", "")
	var new_code = args.get("new_code", "")
	var slice_index = args.get("slice_index", -1)
	var anchor_code = args.get("anchor_code", "")
	var insert_pos = args.get("insert_position", "after")
	
	# --- 1. 安全与基本检查 ---
	var security_error = validate_path_safety(path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "File not found: " + path}
	
	if slice_index < 0:
		return {"success": false, "data": "Invalid slice_index. Must be >= 0."}
		
	if anchor_code.strip_edges().is_empty():
		return {"success": false, "data": "anchor_code cannot be empty."}

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
	
	# --- 3. 切片定位 ---
	var slices = _parse_script_to_slices(base_editor)
	if slice_index >= slices.size():
		return {"success": false, "data": "slice_index %d out of bounds. Total slices: %d" % [slice_index, slices.size()]}
	
	var target_slice = slices[slice_index]
	
	# --- 4. 寻找锚点 ---
	var anchor_match = _find_code_in_slice(base_editor, target_slice, anchor_code)
	
	if not anchor_match.found:
		var msg = "Could not find 'anchor_code' in slice %d.\n" % slice_index
		msg += "Slice Context (Lines %d-%d):\n%s\n...\n" % [target_slice.start_line + 1, target_slice.end_line + 1, _get_preview_lines(base_editor, target_slice, 5)]
		msg += "ACTION: Verify 'anchor_code' exists in this slice."
		return {"success": false, "data": msg}
	
	# --- 5. 计算插入行号 ---
	var insertion_line_index = -1
	
	if insert_pos == "before":
		# 插在锚点开始行的上方
		insertion_line_index = anchor_match.start_line
	else:
		# 插在锚点结束行的下方
		# 注意：insert_text(..., line, col) 是在指定行的上方插入？
		# 让我们复习一下 Godot 的 TextEdit/CodeEdit API
		# insert_text_at_caret 比较常用，但我们要指定位置。
		# insert_text(text, line, col)
		# 如果要在第 N 行后面插，通常是在第 N+1 行开头插。
		insertion_line_index = anchor_match.end_line + 1
	
	# --- 6. 执行插入 ---
	if base_editor.has_method("begin_complex_operation"):
		base_editor.begin_complex_operation()
	
	# 确保新代码格式（自动补齐换行）
	if not new_code.ends_with("\n"):
		new_code += "\n"
	
	# 补齐缩进：尝试读取锚点行的缩进
	var indent = _get_indentation(base_editor.get_line(anchor_match.start_line))
	# 为新代码的每一行添加相同缩进（如果新代码没自带缩进的话）
	# 这里简单处理：给第一行加缩进？不，最好给每一行加。
	# 但通常 LLM 生成的代码可能已经包含了部分缩进，或者完全没有。
	# 策略：如果 new_code 的第一行没有缩进，则给所有行加上锚点的缩进。
	new_code = _apply_indentation(new_code, indent)
	
	base_editor.insert_text(new_code, insertion_line_index, 0)
	
	if base_editor.has_method("end_complex_operation"):
		base_editor.end_complex_operation()
	
	return {
		"success": true, 
		"data": "Successfully inserted code %s slice %d (Line %d)." % [insert_pos, slice_index, insertion_line_index + 1]
	}


# --- 辅助逻辑 (复用自 disable_script_tool，保持一致性) ---

func _parse_script_to_slices(editor: Control) -> Array:
	var slices = []
	var total_lines = editor.get_line_count()
	var current_start = 0
	
	for i in range(total_lines):
		var line = editor.get_line(i).strip_edges()
		if line.begins_with("func ") and i > 0:
			slices.append({"start_line": current_start, "end_line": i - 1})
			current_start = i
	
	if current_start < total_lines:
		slices.append({"start_line": current_start, "end_line": total_lines - 1})
	return slices

func _find_code_in_slice(editor: Control, slice: Dictionary, code_to_find: String) -> Dictionary:
	var slice_start = slice.start_line
	var slice_end = slice.end_line
	
	var find_lines = []
	for line in code_to_find.split("\n"):
		if not line.strip_edges().is_empty():
			find_lines.append(line.strip_edges())
	
	if find_lines.is_empty():
		return {"found": false}
	
	for i in range(slice_start, slice_end + 1):
		var match_cursor = 0
		var current_file_line = i
		var possible_start = -1
		var possible_end = -1
		var mismatch = false
		
		while match_cursor < find_lines.size() and current_file_line <= slice_end:
			var file_line_content = editor.get_line(current_file_line).strip_edges()
			if file_line_content.is_empty():
				current_file_line += 1
				continue
			if file_line_content == find_lines[match_cursor]:
				if match_cursor == 0: possible_start = current_file_line
				possible_end = current_file_line
				match_cursor += 1
				current_file_line += 1
			else:
				mismatch = true
				break
		
		if not mismatch and match_cursor == find_lines.size():
			return {"found": true, "start_line": possible_start, "end_line": possible_end}
			
	return {"found": false}

func _get_preview_lines(editor: Control, slice: Dictionary, count: int) -> String:
	var txt = ""
	var limit = min(slice.end_line, slice.start_line + count)
	for i in range(slice.start_line, limit + 1):
		txt += editor.get_line(i) + "\n"
	return txt

# 获取一行的缩进字符串（Tab 或空格）
func _get_indentation(line: String) -> String:
	var indent = ""
	for char in line:
		if char == " " or char == "\t":
			indent += char
		else:
			break
	return indent

# 智能应用缩进
func _apply_indentation(code: String, indent: String) -> String:
	if indent.is_empty():
		return code
		
	var lines = code.split("\n")
	# 检查第一行是否有缩进
	if lines[0].begins_with(" ") or lines[0].begins_with("\t"):
		# 假设 LLM 已经处理好了缩进，不做修改
		return code
	
	var indented_code = ""
	for i in range(lines.size()):
		var line = lines[i]
		if i == lines.size() - 1 and line.is_empty():
			# 最后一行如果是空的，不需要缩进（通常是 ends_with("\n") 导致的空串）
			continue
		indented_code += indent + line + "\n"
	
	return indented_code
