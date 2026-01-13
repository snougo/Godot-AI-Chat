@tool
extends BaseScriptTool

func _init() -> void:
	tool_name = "disable_script_code"
	tool_description = "Safely comments out a block of code within a specific script slice (logical block). Uses 'slice_index' to locate the area and 'original_code' to verify and pinpoint the lines."

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
	
	# --- 3. 获取所有切片并定位 ---
	var slices = _parse_script_to_slices(base_editor)
	
	if slice_index >= slices.size():
		return {"success": false, "data": "slice_index %d out of bounds. Total slices: %d" % [slice_index, slices.size()]}
	
	var target_slice = slices[slice_index]
	
	# --- 4. 在切片内匹配原始代码 ---
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

# --- 核心辅助逻辑 ---

# 将脚本解析为逻辑切片（Slice）
# Slice 定义：
# - 0: 文件头部（extends, class_name, 顶部变量）
# - 1..N: 每个 func 及其内容
func _parse_script_to_slices(editor: Control) -> Array:
	var slices = []
	var total_lines = editor.get_line_count()
	var current_start = 0
	
	for i in range(total_lines):
		var line = editor.get_line(i).strip_edges()
		# 当遇到 func 且不是第一行时，切分
		if line.begins_with("func ") and i > 0:
			# 之前的块结束于 i - 1
			slices.append({"start_line": current_start, "end_line": i - 1})
			current_start = i
	
	# 添加最后一个块
	if current_start < total_lines:
		slices.append({"start_line": current_start, "end_line": total_lines - 1})
		
	return slices

# 在指定切片范围内查找代码
func _find_code_in_slice(editor: Control, slice: Dictionary, code_to_find: String) -> Dictionary:
	var slice_start = slice.start_line
	var slice_end = slice.end_line
	
	# 预处理要查找的代码：拆分成行，去除非空行的首尾空格
	var find_lines = []
	for line in code_to_find.split("\n"):
		if not line.strip_edges().is_empty():
			find_lines.append(line.strip_edges())
	
	if find_lines.is_empty():
		return {"found": false}
	
	# 遍历切片内的每一行作为起始点尝试匹配
	for i in range(slice_start, slice_end + 1):
		var match_cursor = 0
		var current_file_line = i
		var possible_start = -1
		var possible_end = -1
		var mismatch = false
		
		# 尝试匹配序列
		while match_cursor < find_lines.size() and current_file_line <= slice_end:
			var file_line_content = editor.get_line(current_file_line).strip_edges()
			
			# 跳过文件中的空行和纯注释行（如果 original_code 不包含它们）
			# 这里简化策略：严格匹配非空内容。
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
		
		# 检查是否完整匹配
		if not mismatch and match_cursor == find_lines.size():
			return {"found": true, "start_line": possible_start, "end_line": possible_end}
			
	return {"found": false}

func _get_preview_lines(editor: Control, slice: Dictionary, count: int) -> String:
	var txt = ""
	var limit = min(slice.end_line, slice.start_line + count)
	for i in range(slice.start_line, limit + 1):
		txt += editor.get_line(i) + "\n"
	return txt
