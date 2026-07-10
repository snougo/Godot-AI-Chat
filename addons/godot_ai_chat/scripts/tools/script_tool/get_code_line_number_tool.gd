@tool
extends AiTool

## 在脚本文件中搜索代码并返回行号及代码内容。
##
## 两种模式：
## - exact（默认）：精确匹配文本，返回所有匹配行及其代码内容
## - function：搜索函数定义，返回完整的函数体代码（跳过注释）


func _init() -> void:
	tool_name = "get_code_line_number"
	tool_description = "Get the line number(s) of the matching text in a script file."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the script file."
			},
			"search": {
				"type": "string",
				"description": "For 'exact' mode: the exact text to search for. For 'function' mode: the function name (without 'func' prefix)."
			},
			"mode": {
				"type": "string",
				"enum": ["exact", "function"],
				"description": "'exact': find all exact matches and return line numbers + content. 'function': find a function by name and return its full body."
			}
		},
		"required": ["path", "search", "mode"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var path: String = p_args.get("path", "")
	var search: String = p_args.get("search", "")
	var mode: String = p_args.get("mode", "exact")
	
	# --- 参数校验 ---
	if path.is_empty():
		return ToolResult.fail("Missing parameter: path")
	if search.is_empty():
		return ToolResult.fail("Missing parameter: search")
	
	if not path.begins_with("res://"):
		return ToolResult.fail("Error: Path must start with 'res://'.")
	if ".." in path:
		return ToolResult.fail("Error: Path traversal ('..') is not allowed.")
	
	if not FileAccess.file_exists(path):
		return ToolResult.fail("Error: File not found: " + path)
	
	if mode != "exact" and mode != "function":
		return ToolResult.fail("Error: 'mode' must be 'exact' or 'function'.")
	
	# --- 读取文件 ---
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if not is_instance_valid(file):
		return ToolResult.fail("Error: Failed to open file: " + path)
	
	var content: String = file.get_as_text()
	file.close()
	
	if content.is_empty():
		return ToolResult.fail("Error: File is empty: " + path)
	
	content = content.replace("\r\n", "\n").replace("\r", "\n")
	var lines: PackedStringArray = content.split("\n")
	var file_name := path.get_file()
	
	match mode:
		"exact":
			return _search_exact(content, lines, search, file_name)
		"function":
			return _search_function(lines, search, file_name)
		_:
			return ToolResult.fail("Error: Unknown mode: " + mode)


# ============================================================
#  Exact 模式：精确查找并返回所有匹配行 + 代码内容
# ============================================================

func _search_exact(p_content: String, p_lines: PackedStringArray, p_search: String, p_file_name: String) -> ToolResult:
	var search_len := p_search.length()
	var results: Array[Dictionary] = []  # {line: int, content: String}
	var pos: int = 0
	
	while pos < p_content.length():
		var found := p_content.find(p_search, pos)
		if found == -1:
			break
		
		# 字符位置 → 1-based 行号
		var line_num := 1
		for i in range(found):
			if p_content[i] == "\n":
				line_num += 1
		
		# 词边界检查
		if _is_word_boundary(p_content, found, search_len):
			results.append({"line": line_num, "content": p_lines[line_num - 1]})
			pos = found + search_len
		else:
			pos = found + 1
	
	if results.is_empty():
		return ToolResult.fail("Error: No match found for: '%s'" % p_search)
	
	var msg := "Found %d occurrence(s) of \"%s\" in `%s`:\n" % [results.size(), p_search, p_file_name]
	for r in results:
		msg += "  Line %d: %s\n" % [r["line"], r["content"]]
	
	return ToolResult.ok(msg)


# ============================================================
#  Function 模式：搜索函数定义，返回完整函数体
# ============================================================

func _search_function(p_lines: PackedStringArray, p_func_name: String, p_file_name: String) -> ToolResult:
	# 查找所有匹配的函数定义
	var func_defs: Array[Dictionary] = []  # {def_line: int, indent: int}
	var func_pattern := "func " + p_func_name + "("
	var static_pattern := "static func " + p_func_name + "("
	
	for i in range(p_lines.size()):
		var stripped := p_lines[i].strip_edges()
		
		if (func_pattern in stripped or static_pattern in stripped) and stripped.ends_with(":"):
			var indent := _get_indent(p_lines[i])
			func_defs.append({"def_line": i + 1, "indent": indent})
	
	if func_defs.is_empty():
		return ToolResult.fail("Error: No function named '%s' found in `%s`." % [p_func_name, p_file_name])
	
	var msg := "Found %d definition(s) of function \"%s\" in `%s`:\n\n" % [func_defs.size(), p_func_name, p_file_name]
	
	for fd in func_defs:
		var def_line: int = fd["def_line"]          # 1-based
		var func_indent: int = fd["indent"]
		var end_idx := _find_function_end(p_lines, def_line, func_indent)  # 0-based exclusive
		
		# 函数最后一行（1-based）= end_idx（0-based 的下一函数起始，正好等于最后一行号）
		var last_line := end_idx
		
		msg += "── Function at lines %d-%d ──\n" % [def_line, last_line]
		
		for j in range(def_line - 1, end_idx):
			var line_content := p_lines[j]
			var stripped := line_content.strip_edges()
			# 跳过纯注释行和空行
			if stripped.is_empty() or stripped.begins_with("#"):
				continue
			msg += "  %d: %s\n" % [j + 1, line_content]
		
		msg += "\n"
	
	return ToolResult.ok(msg)


# 查找函数体的结束位置（0-based 独占索引）
# 返回第一个不属于该函数的行的 0-based 索引
# p_def_line 是 1-based 函数定义行
func _find_function_end(p_lines: PackedStringArray, p_def_line: int, p_func_indent: int) -> int:
	# p_def_line 是 1-based，用作 range 起点时当作 0-based 使用，
	# 自动跳过了函数定义行本身，从函数体第一行开始扫描
	for i in range(p_def_line, p_lines.size()):
		var line := p_lines[i]
		var stripped := line.strip_edges()
		
		# 跳过空行和注释行
		if stripped.is_empty() or stripped.begins_with("#"):
			continue
		
		var line_indent := _get_indent(line)
		
		# 缩进 <= 函数定义缩进 → 函数体结束
		if line_indent <= p_func_indent:
			return i  # 0-based，第一个不属于该函数的行
		
		# 遇到 class/extends/tool 等顶层关键字也结束
		if stripped.begins_with("class ") or stripped.begins_with("extends "):
			if line_indent <= p_func_indent + 1:
				return i
	
	return p_lines.size()  # 到文件末尾


# 获取行的缩进级别
static func _get_indent(p_line: String) -> int:
	var indent := 0
	for i in range(p_line.length()):
		var c := p_line[i]
		if c == "\t":
			indent += 1
		elif c == " ":
			indent += 1
		else:
			break
	return indent


# ============================================================
#  词边界检查
# ============================================================

static func _is_word_boundary(p_content: String, p_match_pos: int, p_match_len: int) -> bool:
	if p_match_pos > 0:
		if _is_word_char(p_content[p_match_pos - 1]):
			return false
	var after_pos := p_match_pos + p_match_len
	if after_pos < p_content.length():
		if _is_word_char(p_content[after_pos]):
			return false
	return true


static func _is_word_char(p_char: String) -> bool:
	if p_char.length() != 1:
		return false
	var c := p_char.unicode_at(0)
	return (c >= 0x30 and c <= 0x39) \
		or (c >= 0x41 and c <= 0x5A) \
		or (c >= 0x61 and c <= 0x7A) \
		or c == 0x5F
