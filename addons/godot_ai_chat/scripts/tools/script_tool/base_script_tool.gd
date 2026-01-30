@tool
class_name BaseScriptTool
extends AiTool

## 脚本工具的基类

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
		var content: String = _get_code_range_formatted(p_editor, slice.start_line, slice.end_line)
		result += "**[Slice %d] [%s] (Lines %d-%d)**\n" % [i + 1, slice.type, slice.start_line + 1, slice.end_line + 1]
		result += "```gdscript\n%s```\n\n" % content
	return result


## 核心解析逻辑：将代码解析为细粒度切片
func parse_script_to_slices(p_code: String) -> Array:
	var lines: PackedStringArray = p_code.split("\n")
	var slices := []
	var count := lines.size()
	if count == 0: return []
	
	var current_start := 0
	var i := 0
	
	while i < count:
		# 1. 吞噬前置的注释和空行 (Context)
		# 这些行属于下一个即将开始的切片
		var context_start := i
		while i < count:
			var line_stripped := lines[i].strip_edges()
			if line_stripped.is_empty() or line_stripped.begins_with("#"):
				i += 1
			else:
				break
		
		if i >= count:
			# 文件末尾的注释/空行归为最后一个切片，或者单独成片
			if slices.size() > 0:
				slices[-1]["end_line"] = count - 1
			break
		
		# 2. 识别切片类型和主体
		var slice_start := context_start
		var current_line := lines[i]
		var type := _identify_line_type(current_line)
		
		# 3. 确定切片结束位置
		# 如果是 Scope 类型 (func, class)，需要寻找缩进闭合
		# 如果是 Single 类型 (var, signal)，通常是一行，但可能有折行
		var body_start := i
		i += 1 # 移动到下一行准备检查
		
		if type in ["FUNC", "CLASS"]:
			while i < count:
				var line := lines[i]
				if line.strip_edges().is_empty():
					i += 1
					continue
				
				# 如果遇到缩进为0且不是注释的行，说明当前 Scope 结束
				if not line.begins_with(" ") and not line.begins_with("\t") and not line.strip_edges().begins_with("#"):
					break
				i += 1
		else:
			# 对于非 Scope 类型，检查是否有多行定义 (例如 var x = [\n ... ])
			# 简单策略：只要下一行有缩进，就视为延续
			while i < count:
				var line := lines[i]
				if line.strip_edges().is_empty():
					# 空行可能意味着单行声明结束，也可能是多行声明的内部空行
					# 预读下一行非空行
					var next_code_idx := _find_next_non_empty_line(lines, i + 1)
					if next_code_idx == -1:
						i = count # 后面全是空行，结束
						break
					var next_line := lines[next_code_idx]
					if next_line.begins_with(" ") or next_line.begins_with("\t"):
						i = next_code_idx + 1 # 继续包含
					else:
						# 下一行顶格，说明当前块结束。
						# 注意：中间的空行应该归属给谁？通常归属给上一个块。
						i = next_code_idx 
						break
				elif line.begins_with(" ") or line.begins_with("\t"):
					i += 1
				else:
					break
		
		# 4. 记录切片
		# i 现在指向下一个切片的开始（或者 Context 的开始）
		# 当前切片范围是 [slice_start, i - 1]
		slices.append({
			"start_line": slice_start,
			"end_line": i - 1,
			"type": type,
			"signature": lines[body_start].strip_edges()
		})
		
		# 下一次循环从 i 开始
	
	return slices


## 查找最匹配的切片
func find_best_match_slice(p_editor: CodeEdit, p_signature: String) -> Dictionary:
	var slices: Array = parse_script_to_slices(p_editor.text)
	var target := p_signature.strip_edges()
	
	# 1. 尝试完全匹配 Signature
	for slice in slices:
		if slice.signature == target:
			return {"found": true, "slice": slice}
	
	# 2. 尝试前缀匹配 (例如用户只给了 "func _ready")
	for slice in slices:
		if slice.signature.begins_with(target):
			return {"found": true, "slice": slice}
			
	# 3. 尝试包含匹配 (作为最后手段)
	for slice in slices:
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


func _find_next_non_empty_line(p_lines: PackedStringArray, p_from: int) -> int:
	for k in range(p_from, p_lines.size()):
		if not p_lines[k].strip_edges().is_empty():
			return k
	return -1


func _get_code_range_formatted(p_editor: CodeEdit, p_start: int, p_end: int) -> String:
	var result := ""
	var line_count_width := str(p_editor.get_line_count()).length()
	for i in range(p_start, p_end + 1):
		result += "%*d | %s\n" % [line_count_width, i + 1, p_editor.get_line(i)]
	
	return result


func _get_code_edit(p_path: String) -> CodeEdit:
	# (保持原有逻辑: 查找或打开编辑器，并聚焦)
	var script_editor := EditorInterface.get_script_editor()
	if not p_path.is_empty() and FileAccess.file_exists(p_path):
		var res = load(p_path)
		if res is Script: EditorInterface.edit_script(res)
	
	EditorInterface.set_main_screen_editor("Script")
	var editor_base = script_editor.get_current_editor()
	if editor_base:
		return editor_base.get_base_editor() as CodeEdit
	
	return null


func _focus_script_editor() -> void:
	EditorInterface.set_main_screen_editor("Script")
