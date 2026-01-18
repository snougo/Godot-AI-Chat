@tool
extends AiTool
class_name BaseScriptTool

# 默认允许的扩展名白名单
const DEFAULT_ALLOWED_EXTENSIONS = ["gd", "gdshader"]

var _func_regex: RegEx

func _init() -> void:
	_func_regex = RegEx.new()
	# 匹配 static func 或 func，允许前导空格
	_func_regex.compile("^\\s*(static\\s+)?func\\s+")

# --- 基础验证 ---

# 统一的文件扩展名检查函数
func validate_file_extension(path: String, allowed_extensions: Array = []) -> String:
	if allowed_extensions.is_empty():
		allowed_extensions = DEFAULT_ALLOWED_EXTENSIONS
	
	var extension: String = path.get_extension().to_lower()
	if extension not in allowed_extensions:
		return "Error: File extension '%s' is not allowed. Allowed extensions: %s" % [extension, str(allowed_extensions)]
	
	return ""

# --- 核心逻辑：切片解析 (统一算法) ---

# 将脚本代码解析为逻辑切片 (Slice)
# 基于字符串处理，确保"读"与"写"使用同一套逻辑
func _parse_script_to_slices(code: String) -> Array:
	var lines = code.split("\n")
	var slices = []
	var current_start = 0
	
	for i in range(lines.size()):
		var line = lines[i]
		
		# 使用 Regex 统一识别函数入口
		if _func_regex.search(line):
			var split_idx = i
			var k = i - 1
			
			# 向上回溯包含连续的注释行
			while k >= current_start:
				var prev_line = lines[k].strip_edges()
				if prev_line.begins_with("#"):
					split_idx = k 
					k -= 1
				else:
					break
			
			# 避免文件开头的 func 导致切出空片
			if split_idx > current_start:
				slices.append({"start_line": current_start, "end_line": split_idx - 1})
				current_start = split_idx
	
	# 添加最后一个块
	if current_start < lines.size():
		slices.append({"start_line": current_start, "end_line": lines.size() - 1})
	elif lines.size() == 0:
		# 处理空文件情况
		slices.append({"start_line": 0, "end_line": 0})
		
	return slices

# --- 核心逻辑：代码查找与处理 ---

# 在指定切片范围内查找代码
# editor: 编辑器控件对象 (用于 get_line)
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
		
		# 尝试从当前行开始匹配序列
		while match_cursor < find_lines.size() and current_file_line <= slice_end:
			var file_line_content = editor.get_line(current_file_line).strip_edges()
			
			# 跳过文件中的空行
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

# 获取上下文预览
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

# 智能应用缩进到多行代码
func _apply_indentation(code: String, indent: String) -> String:
	if indent.is_empty():
		return code
		
	var lines = code.split("\n")
	# 如果第一行已有缩进，假设代码块已格式化好，不再处理
	if lines[0].begins_with(" ") or lines[0].begins_with("\t"):
		return code
	
	var indented_code = ""
	for i in range(lines.size()):
		var line = lines[i]
		if i == lines.size() - 1 and line.is_empty():
			continue # 忽略末尾空行
		indented_code += indent + line + "\n"
	
	return indented_code
