@tool
class_name BaseScriptTool
extends AiTool

## 脚本工具的基类。
## 提供脚本解析、代码查找和编辑器操作的通用功能。

# --- Enums / Constants ---

## 默认允许的扩展名白名单
const DEFAULT_ALLOWED_EXTENSIONS: Array[String] = ["gd", "gdshader"]

# --- Private Vars ---

var _func_regex: RegEx


# --- Public Functions ---

## 验证文件扩展名
## [param p_path]: 文件路径
## [param p_allowed_extensions]: 允许的扩展名数组（可选）
## [return]: 空字符串表示有效，否则返回错误信息
func validate_file_extension(p_path: String, p_allowed_extensions: Array = []) -> String:
	if p_allowed_extensions.is_empty():
		p_allowed_extensions = DEFAULT_ALLOWED_EXTENSIONS
	
	var extension: String = p_path.get_extension().to_lower()
	if extension not in p_allowed_extensions:
		return "Error: File extension '%s' is not allowed. Allowed extensions: %s" % [extension, str(p_allowed_extensions)]
	
	return ""


## 获取带有行号的代码内容
## [param p_editor]: 编辑器控件
## [return]: 格式化后的代码字符串
func get_numbered_code(p_editor: Control) -> String:
	var total_lines: int = p_editor.get_line_count()
	var result: String = ""
	
	# 计算最大行号的位数，用于对齐
	var padding: int = str(total_lines).length()
	
	for i in range(total_lines):
		var line_content: String = p_editor.get_line(i)
		# 格式: 行号 | 内容
		# %*d 表示动态宽度的整数，这里用 padding
		result += "%*d | %s\n" % [padding, i + 1, line_content]
		
	return result


## 将脚本代码解析为逻辑切片
## [param p_code]: 脚本代码字符串
## [return]: 切片数组，每个切片包含 start_line 和 end_line
func parse_script_to_slices(p_code: String) -> Array:
	var lines: PackedStringArray = p_code.split("\n")
	var slices := []
	var current_start := 0
	
	var func_regex := _get_func_regex()
	
	for i in range(lines.size()):
		var line: String = lines[i]
		
		if func_regex.search(line):
			var split_idx := i
			var k := i - 1
			
			while k >= current_start:
				var prev_line: String = lines[k].strip_edges()
				if prev_line.begins_with("#"):
					split_idx = k 
					k -= 1
				else:
					break
			
			if split_idx > current_start:
				slices.append({"start_line": current_start, "end_line": split_idx - 1})
				current_start = split_idx
	
	if current_start < lines.size():
		slices.append({"start_line": current_start, "end_line": lines.size() - 1})
	elif lines.size() == 0:
		slices.append({"start_line": 0, "end_line": 0})
	
	return slices


## 在指定切片范围内查找代码
## [param p_editor]: 编辑器控件对象 (CodeEdit)
## [param p_slice]: 切片字典
## [param p_code_to_find]: 要查找的代码
## [return]: 包含 found、start_line、end_line 的字典
func find_code_in_slice(p_editor: Control, p_slice: Dictionary, p_code_to_find: String) -> Dictionary:
	var slice_start: int = p_slice.start_line
	var slice_end: int = p_slice.end_line
	
	var find_lines := []
	for line in p_code_to_find.split("\n"):
		if not line.strip_edges().is_empty():
			find_lines.append(line.strip_edges())
	
	if find_lines.is_empty():
		return {"found": false}
	
	var max_lines: int = p_editor.get_line_count()
	if slice_end >= max_lines:
		slice_end = max_lines - 1
	
	for i in range(slice_start, slice_end + 1):
		var match_cursor := 0
		var current_file_line := i
		var possible_start := -1
		var possible_end := -1
		var mismatch := false
		
		while match_cursor < find_lines.size() and current_file_line <= slice_end:
			var file_line_content: String = p_editor.get_line(current_file_line).strip_edges()
			
			if file_line_content.is_empty():
				current_file_line += 1
				continue
			
			if file_line_content == find_lines[match_cursor]:
				if match_cursor == 0:
					possible_start = current_file_line
				possible_end = current_file_line
				match_cursor += 1
				current_file_line += 1
			else:
				mismatch = true
				break
		
		if not mismatch and match_cursor == find_lines.size():
			return {"found": true, "start_line": possible_start, "end_line": possible_end}
	
	return {"found": false}


## 获取代码操作后的快照预览
## [param p_editor]: 编辑器控件对象
## [param p_center_line]: 中心行号
## [param p_context_lines]: 上下文行数
## [return]: 快照字符串
func get_code_snapshot(p_editor: Control, p_center_line: int, p_context_lines: int = 5) -> String:
	var total_lines: int = p_editor.get_line_count()
	var start_line: int = max(0, p_center_line - p_context_lines)
	var end_line: int = min(total_lines - 1, p_center_line + p_context_lines)
	
	var snapshot: String = "\n**Result Snapshot (Lines %d-%d):**\n```gdscript\n" % [start_line + 1, end_line + 1]
	
	for i in range(start_line, end_line + 1):
		var marker: String = " "
		if i == p_center_line:
			marker = ">"
			
		var line_content: String = p_editor.get_line(i)
		snapshot += "%s %03d | %s\n" % [marker, i + 1, line_content]
	
	snapshot += "```\n"
	return snapshot


## 获取一行的缩进字符串
## [param p_line]: 行文本
## [return]: 缩进字符串
func get_indentation(p_line: String) -> String:
	var indent := ""
	for char in p_line:
		if char == " " or char == "\t":
			indent += char
		else:
			break
	return indent


## 智能应用缩进到多行代码
## [param p_code]: 代码字符串
## [param p_indent]: 缩进字符串
## [return]: 应用缩进后的代码
func apply_indentation(p_code: String, p_indent: String) -> String:
	if p_indent.is_empty():
		return p_code
	
	var lines: PackedStringArray = p_code.split("\n")
	if lines[0].begins_with(" ") or lines[0].begins_with("\t"):
		return p_code
	
	var indented_code := ""
	for i in range(lines.size()):
		var line: String = lines[i]
		if i == lines.size() - 1 and line.strip_edges().is_empty():
			continue 
		indented_code += p_indent + line + "\n"
	
	return indented_code


# --- Helpers (Protected) ---

func _open_script_deferred(path: String) -> void:
	if FileAccess.file_exists(path):
		var res = load(path)
		if res and (res is Script):
			EditorInterface.edit_script(res)


## 获取 CodeEdit 实例。如果 path 不为空且不是当前脚本，会尝试打开它。
## [param p_path]: 目标脚本路径。如果为空，尝试获取当前活跃的脚本编辑器。
## [return]: CodeEdit 控件或 null
func _get_code_edit(p_path: String) -> CodeEdit:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	
	# 1. 检查当前打开的脚本是否匹配
	var current_script: Script = script_editor.get_current_script()
	if current_script and not p_path.is_empty() and current_script.resource_path == p_path:
		return _get_active_code_edit()
	
	# 2. 如果不匹配，或者路径不为空，尝试加载并打开
	if not p_path.is_empty():
		if not FileAccess.file_exists(p_path):
			return null
		var res = load(p_path)
		if not res or not (res is Script):
			return null
		EditorInterface.edit_script(res)
		# 此时编辑器应该已经切换，获取当前的 code edit
		return _get_active_code_edit()
	
	# 3. 路径为空，直接返回当前活跃的
	return _get_active_code_edit()


## 内部：获取当前 Tab 的 CodeEdit
func _get_active_code_edit() -> CodeEdit:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var current_editor_base: ScriptEditorBase = script_editor.get_current_editor()
	if not current_editor_base:
		return null
	
	var base_control: Control = current_editor_base.get_base_editor()
	if base_control is CodeEdit:
		return base_control
	return null


# --- Private Functions ---

## 获取函数正则表达式对象（懒加载）
## [return]: RegEx 对象
func _get_func_regex() -> RegEx:
	if _func_regex == null:
		_func_regex = RegEx.new()
		_func_regex.compile("^\\s*(static\\s+)?func\\s+")
	return _func_regex
