@tool
class_name BaseScriptTool
extends AiTool

## 脚本工具的基类 (v3: Top-level Gaps Only)

# --- Enums / Constants ---

const DEFAULT_ALLOWED_EXTENSIONS: Array[String] = ["gd", "gdshader"]

# --- Private Vars ---

var _regex_cache: Dictionary = {}


# --- Public Functions ---

## 验证文件扩展名
func validate_file_extension(p_path: String, p_allowed_extensions: Array = []) -> String:
	if p_allowed_extensions.is_empty():
		p_allowed_extensions = DEFAULT_ALLOWED_EXTENSIONS
	var extension: String = p_path.get_extension().to_lower()
	if extension not in p_allowed_extensions:
		return "Error: File extension '%s' is not allowed. Allowed: %s" % [extension, str(p_allowed_extensions)]
	return ""


## 获取带类型标记的切片化代码视图
## [param p_editor]: CodeEdit 编辑器实例
## [param p_file_path]: 可选的文件路径，用于覆盖 CodeEdit 的 meta 数据
func get_sliced_code_view(p_editor: CodeEdit, p_file_path: String = "") -> String:
	var code: String = p_editor.text
	var slices: Array = parse_script_to_slices(code)
	var result: String = "### Script Structure View\n"
	
	# 优先使用传入的路径，否则尝试从 CodeEdit 的 meta 获取
	var display_path: String = p_file_path
	if display_path.is_empty() and p_editor.has_meta("_edit_res_path"):
		display_path = p_editor.get_meta("_edit_res_path")
	if display_path.is_empty():
		display_path = "Untitled"
	
	result += "File: %s\n\n" % display_path
	
	for i in range(slices.size()):
		var slice: Dictionary = slices[i]
		var start_l = slice.start_line + 1
		var end_l = slice.end_line + 1
		
		if slice.type == "GAP":
			# GAP 类型简化显示，作为插入锚点
			result += "**[Slice %d] [GAP] (Lines %d-%d)**\n" % [i + 1, start_l, end_l]
			result += "< EMPTY LINES >\n\n"
		else:
			# 逻辑切片显示完整内容
			var content: String = _get_code_range_formatted(p_editor, slice.start_line, slice.end_line)
			result += "**[Slice %d] [%s] (Lines %d-%d)**\n" % [i + 1, slice.type, start_l, end_l]
			result += "```gdscript\n%s```\n\n" % content
	
	return result


## 将代码解析为细粒度切片
func parse_script_to_slices(p_code: String) -> Array:
	var lines: PackedStringArray = p_code.split("\n")
	var slices := []
	var count := lines.size()
	var i := 0
	
	while i < count:
		var line := lines[i]
		var stripped := line.strip_edges()
		
		# 1. 识别并处理 GAP (仅顶层空行)
		if stripped.is_empty():
			var start := i
			# 贪婪吞噬后续空行
			while i < count and lines[i].strip_edges().is_empty():
				i += 1
			
			slices.append({
				"start_line": start,
				"end_line": i - 1,
				"type": "GAP",
				"signature": "<EMPTY LINES>"
			})
			continue
		
		# 2. 识别逻辑切片
		var slice_start := i
		var body_start := -1
		var type := ""
		var has_leading_comments := false
		
		# 2.1 扫描前置注释，判断注释归属
		while i < count:
			var l_scan := lines[i]
			var s_scan := l_scan.strip_edges()
			
			if s_scan.is_empty():
				# 遇到空行，根据后续内容决定注释归属
				if has_leading_comments:
					# 检查空行后是否是函数定义
					if i + 1 < count and _is_function_definition(lines[i + 1]):
						# 注释属于下一个函数，吞噬空行继续
						i += 1
						continue
					else:
						# 注释是独立的
						type = "COMMENT"
						body_start = slice_start
						break
				else:
					# 没有前置注释，直接退出
					break
					
			elif s_scan.begins_with("#"):
				has_leading_comments = true
				i += 1
				continue
				
			else:
				# 遇到非空非注释行 - 代码开始
				body_start = i
				type = _identify_line_type(l_scan)
				break
		
		# 2.2 边界处理
		if body_start == -1:
			# 到了文件末尾，只剩下注释
			if type == "": type = "COMMENT"
			if body_start == -1: body_start = slice_start
			
			slices.append({
				"start_line": slice_start,
				"end_line": i - 1,
				"type": type,
				"signature": lines[slice_start].strip_edges()
			})
			continue
		
		# 2.3 扫描代码体 (Scope)
		# i 现在指向 body_start (代码定义行)
		i += 1 # 进下一行
		
		if type in ["FUNC", "CLASS", "TEST_FUNC"]:
			# Scope 模式：吞噬所有内容，直到遇到顶格非注释代码
			while i < count:
				var l_body := lines[i]
				var s_body := l_body.strip_edges()
				
				if s_body.is_empty():
					# 空行：在 Scope 内部，空行被视为函数体的一部分，继续吞噬
					i += 1
					continue
				
				if l_body.begins_with(" ") or l_body.begins_with("\t"):
					# 缩进内容：继续吞噬
					i += 1
					continue
					
				if s_body.begins_with("#"):
					# 遇到顶格注释：检查是否与下一个函数相关
					if i + 1 < count and _is_function_definition(lines[i + 1]):
						# 注释属于下一个函数，停止当前 slice
						break
					else:
						# 函数体内部的注释，继续吞噬
						i += 1
						continue
					
				else:
					# 遇到顶格代码：Scope 结束
					break
		else:
			# Non-Scope 模式 (VAR, SIGNAL 等)
			# 遇到空行或顶格代码都切断
			while i < count:
				var l_body := lines[i]
				if l_body.strip_edges().is_empty():
					break
				
				# 允许缩进延续 (如多行数组定义)
				if l_body.begins_with(" ") or l_body.begins_with("\t"):
					i += 1
				else:
					break
		
		# 2.4 结算逻辑切片
		slices.append({
			"start_line": slice_start,
			"end_line": i - 1,
			"type": type,
			"signature": lines[body_start].strip_edges()
		})
	
	return slices


## 查找最匹配的切片
func find_best_match_slice(p_editor: CodeEdit, p_signature: String) -> Dictionary:
	var slices: Array = parse_script_to_slices(p_editor.text)
	var target := p_signature.strip_edges()
	
	# 忽略 GAP 类型的切片进行匹配
	var valid_slices = slices.filter(func(s): return s.type != "GAP")
	
	# 1. 完全匹配
	for slice in valid_slices:
		if slice.signature == target:
			return {"found": true, "slice": slice}
	
	# 2. 前缀匹配
	for slice in valid_slices:
		if slice.signature.begins_with(target):
			return {"found": true, "slice": slice}
			
	# 3. 包含匹配
	for slice in valid_slices:
		if target in slice.signature:
			return {"found": true, "slice": slice}
			
	return {"found": false}

## 查找代码中对特定签名的引用
## [param p_code]: 完整代码文本
## [param p_target_signature]: 目标签名（如 "test_function", "test_variable"）
## [return]: 包含引用信息的数组，每项包含 {line, context, type}
func find_references(p_code: String, p_target_signature: String) -> Array:
	var lines: PackedStringArray = p_code.split("\n")
	var references := []
	
	# 提取目标名称（从签名中提取函数名/变量名）
	var target_name := _extract_name_from_signature(p_target_signature)
	if target_name.is_empty():
		return references
	
	var i := 0
	while i < lines.size():
		var line := lines[i]
		var stripped := line.strip_edges()
		
		# 跳过空行和注释
		if stripped.is_empty() or stripped.begins_with("#"):
			i += 1
			continue
		
		# 跳过定义行本身
		if _contains_signature_definition(stripped, target_name):
			i += 1
			continue
		
		# 检查是否包含引用
		if _contains_reference(line, target_name):
			# 获取上下文（前后各2行）
			var context_start := max(0, i - 2)
			var context_end := min(lines.size() - 1, i + 2)
			var context_lines := []
			for j in range(context_start, context_end + 1):
				var prefix := "  " if j != i else "->"
				context_lines.append("%s %d | %s" % [prefix, j + 1, lines[j]])
			
			references.append({
				"line": i + 1,
				"context": "\n".join(context_lines),
				"type": _identify_reference_type(line)
			})
		
		i += 1
	
	return references

# --- Helper Function ---

func _identify_line_type(p_line: String) -> String:
	var s := p_line.strip_edges()
	if s.begins_with("func") or s.begins_with("static func"): return "FUNC"
	if s.begins_with("var") or s.begins_with("@onready") or s.begins_with("@export"): return "VAR"
	if s.begins_with("signal"): return "SIGNAL"
	if s.begins_with("const"): return "CONST"
	if s.begins_with("enum"): return "ENUM"
	if s.begins_with("class_name"): return "CLASS_NAME"
	if s.begins_with("extends"): return "EXTENDS"
	if s.begins_with("class "): return "CLASS"
	if s.begins_with("@tool"): return "TOOL"
	return "OTHER"


func _get_code_range_formatted(p_editor: CodeEdit, p_start: int, p_end: int) -> String:
	var result := ""
	var line_count_width := str(p_editor.get_line_count()).length()
	for i in range(p_start, p_end + 1):
		result += "%*d | %s\n" % [line_count_width, i + 1, p_editor.get_line(i)]
	
	return result


func _get_code_edit(p_path: String) -> CodeEdit:
	# [修复点 1]：防止主动打开受限路径 (针对 get_script_slices 等)
	if not p_path.is_empty():
		var safety_err := validate_path_safety(p_path)
		if not safety_err.is_empty():
			AIChatLogger.error("[BaseScriptTool] Security Error: " + safety_err)
			return null
	
	var script_editor := EditorInterface.get_script_editor()
	
	# 尝试加载并切换到指定脚本
	if not p_path.is_empty() and FileAccess.file_exists(p_path):
		var res = load(p_path)
		if res is Script: 
			EditorInterface.edit_script(res)
	
	EditorInterface.set_main_screen_editor("Script")
	
	# [修复点 2]：防止操作当前已打开的受限文件 (针对 insert_new_slice 等)
	# 即使脚本已经手动被用户打开，AI 工具也应该拒绝修改它
	var current_script := script_editor.get_current_script()
	if current_script:
		var current_path := current_script.resource_path
		var safety_err := validate_path_safety(current_path)
		if not safety_err.is_empty():
			AIChatLogger.error("[BaseScriptTool] Security Block: Cannot edit file in restricted path: " + current_path)
			return null
	
	# 获取 CodeEdit 实例
	var editor_base = script_editor.get_current_editor()
	if editor_base:
		return editor_base.get_base_editor() as CodeEdit
	
	return null



func _focus_script_editor() -> void:
	EditorInterface.set_main_screen_editor("Script")


# 获取当前已打开脚本的 CodeEdit 实例（不打开新脚本）
func _get_current_code_edit() -> CodeEdit:
	var script_editor := EditorInterface.get_script_editor()
	
	# 确保当前有打开的脚本
	var current_script := script_editor.get_current_script()
	if not current_script:
		return null
	
	var current_path := current_script.resource_path
	
	# [Security Check] 防止操作受限路径的文件
	var safety_err := validate_path_safety(current_path)
	if not safety_err.is_empty():
		AIChatLogger.warn("[BaseScriptTool] Security Block: Cannot edit file in restricted path: " + current_path)
		return null
	
	EditorInterface.set_main_screen_editor("Script")
	
	# 获取 CodeEdit 实例
	var editor_base = script_editor.get_current_editor()
	if editor_base:
		return editor_base.get_base_editor() as CodeEdit
	
	return null


# 从签名中提取名称
func _extract_name_from_signature(p_signature: String) -> String:
	var sig := p_signature.strip_edges()
	
	# 处理各种签名格式
	# func name() -> name
	# var name = value
	# const name = value
	# signal name()
	# @onready var name
	# @export var name
	
	if sig.begins_with("func") or sig.begins_with("static func"):
		var paren_idx := sig.find("(")
		if paren_idx > 0:
			var func_part := sig.substr(0, paren_idx)
			var space_idx := func_part.rfind(" ")  # 修正：使用 rfind() 代替 find_last()
			if space_idx > 0:
				return func_part.substr(space_idx + 1).strip_edges()
	
	elif sig.begins_with("var") or sig.begins_with("const"):
		var space_idx := sig.find(" ")
		if space_idx > 0:
			var var_part := sig.substr(space_idx + 1).strip_edges()
			var assign_idx := var_part.find("=")
			if assign_idx > 0:
				return var_part.substr(0, assign_idx).strip_edges()
			var colon_idx := var_part.find(":")
			if colon_idx > 0:
				return var_part.substr(0, colon_idx).strip_edges()
			return var_part
	
	elif sig.begins_with("signal"):
		var space_idx := sig.find(" ")
		if space_idx > 0:
			var signal_part := sig.substr(space_idx + 1).strip_edges()
			var paren_idx := signal_part.find("(")
			if paren_idx > 0:
				return signal_part.substr(0, paren_idx)
			return signal_part
	
	return ""


# 检查行是否包含签名定义
func _contains_signature_definition(p_line: String, p_name: String) -> bool:
	var stripped := p_line.strip_edges()
	
	# 检查是否是定义行
	if stripped.begins_with("func ") or stripped.begins_with("static func "):
		return stripped.begins_with("func %s(" % p_name) or stripped.begins_with("static func %s(" % p_name)
	
	if stripped.begins_with("var ") or stripped.begins_with("const "):
		var keywords := ["var", "const", "@onready", "@export"]
		for kw in keywords:
			if stripped.begins_with(kw + " "):
				var rest := stripped.substr(kw.length() + 1).strip_edges()
				return rest.begins_with(p_name + " ") or rest.begins_with(p_name + ":") or rest.begins_with(p_name + "=")
	
	if stripped.begins_with("signal "):
		return stripped.begins_with("signal %s(" % p_name) or stripped == "signal %s" % p_name
	
	return false


# 检查行是否包含引用
func _contains_reference(p_line: String, p_name: String) -> bool:
	# 简单检查：目标名称是否作为独立的标识符出现
	# 使用正则表达式匹配单词边界
	var pattern := "\\b%s\\b" % p_name.replace(".", "\\.")
	var regex := RegEx.new()
	regex.compile(pattern)
	
	if regex.search(p_line) != null:
		return true
	
	return false


# 识别引用类型
func _identify_reference_type(p_line: String) -> String:
	var stripped := p_line.strip_edges()
	
	if stripped.contains("(") and (stripped.contains("%s(") or stripped.contains("%s .")):
		return "function_call"
	
	if stripped.contains("=") or stripped.contains("+=") or stripped.contains("-="):
		return "assignment"
	
	if stripped.contains("if ") or stripped.contains("elif ") or stripped.contains("while ") or stripped.contains("for "):
		return "condition"
	
	if stripped.contains("return "):
		return "return"
	
	return "other"


# 判断一行是否是函数定义
func _is_function_definition(p_line: String) -> bool:
	var stripped := p_line.strip_edges()
	return stripped.begins_with("func ") or stripped.begins_with("static func ")
