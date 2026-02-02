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
func get_sliced_code_view(p_editor: CodeEdit) -> String:
	var code: String = p_editor.text
	var slices: Array = parse_script_to_slices(code)
	var result: String = "### Script Structure View\n"
	result += "File: %s\n\n" % [p_editor.get_meta("_edit_res_path") if p_editor.has_meta("_edit_res_path") else "Untitled"]
	
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


## 核心解析逻辑：将代码解析为细粒度切片 (v3: Scope-Aware Gaps)
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
			
		# 2. 识别逻辑切片 (代码或独立注释)
		var slice_start := i
		var body_start := -1 # 实际代码定义的起始行 (跳过前置注释)
		var type := ""
		
		# 2.1 扫描前置注释 (Context)
		while i < count:
			var l_scan := lines[i]
			var s_scan := l_scan.strip_edges()
			
			if s_scan.is_empty():
				# 注释后遇到了空行 -> 说明之前的注释是独立的
				type = "COMMENT"
				body_start = slice_start # 签名取第一行注释
				break 
			elif not s_scan.begins_with("#"):
				# 遇到了非空且非注释行 -> 代码开始
				body_start = i
				type = _identify_line_type(l_scan)
				break
			else:
				# 继续吞噬注释
				i += 1
		
		# 2.2 边界处理
		if body_start == -1:
			if type == "": type = "COMMENT"
			if body_start == -1: body_start = slice_start
			
			# 如果是因为空行 break 的，i 现在指向那个空行
			# 结算当前切片
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
		
		if type in ["FUNC", "CLASS", "TEST_FUNC"]: # 将来可能支持的类型
			# Scope 模式：吞噬所有内容，直到遇到顶格非注释代码
			while i < count:
				var l_body := lines[i]
				var s_body := l_body.strip_edges()
				
				if s_body.is_empty():
					# 空行：在 Scope 内部，空行被视为函数体的一部分，继续吞噬
					i += 1
					continue
				
				if l_body.begins_with(" ") or l_body.begins_with("\t") or s_body.begins_with("#"):
					# 缩进内容或注释：继续吞噬
					i += 1
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
