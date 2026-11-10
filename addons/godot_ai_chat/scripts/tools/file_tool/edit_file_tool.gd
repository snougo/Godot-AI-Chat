extends AiTool

# 文本文件编辑工具（精确替换 / 整体重写）。
#
# 用途：直接对磁盘上已存在的文本文件做修改，无需经过脚本编辑器。
# - 精确替换：target_string 必须逐字符匹配（含缩进），且在文件中唯一命中
# - 整体重写：提供 rewrite 时忽略 edits，整文件覆盖
# - 一次调用的 edits 是原子的：任一 edit 未命中 / 不唯一 / 编译失败，都不会写盘
#
# 未命中时会用 target_string 的首个有效行做探针，返回最接近的候选行，
# 用于区分「缩进 / tab 与空格不符」与「文件内容已变」——两者的补救方式完全不同。
#
# 路径安全：
# - 受统一黑名单管控（/.git/、/.import/、/.godot/、/android/、/addons/）
# - EXTRA_WRITE_ALLOWLIST 可显式追加允许写入的目录前缀（默认空 = 不追加）
#
# 换行与 BOM：内部统一按 LF 匹配，写回时恢复原文件的行尾风格与 BOM，
# 因此不必关心目标文件是 LF 还是 CRLF。
#
# .gd 目标会在写回前做静态编译检查：存在编译错误时不写盘、文件保持原状
# （可用 skip_compile_check 跳过）。
#
# 若目标文件正在脚本编辑器中打开且有未保存改动，请先在编辑器内保存，
# 否则编辑器 buffer 稍后保存时会覆盖本次改动。


# --- Constants ---

# 允许编辑的文本类扩展名（二进制资源如 .scn/.res/.png 不在列）
const EDITABLE_EXTENSIONS: Array[String] = ["md", "txt", "json", "cfg", "csv", "glsl", "gdshader", "gd"]

# 未命中诊断：探针行的最小长度。过短的行（如 "}"、"pass"）会命中大量无关位置，没有诊断价值
const MIN_PROBE_CHARS: int = 8

# 未命中诊断：最多返回的候选行数
const MAX_MISS_HINTS: int = 3

# 额外允许写入的路径前缀（默认空 = 完全遵循黑名单）。
# 默认黑名单禁止写入 /addons/。若确实需要让 AI 修改某个插件，可在此显式列出该插件目录，
# 例如 ["res://addons/poly_model/"]。
# 只有[人类编辑本文件]才能放宽该限制 —— AI 无法自行修改自己运行所依赖的这份脚本。
const EXTRA_WRITE_ALLOWLIST: Array[String] = []

# GDScript 静态编译检查器（仅对 .gd 生效）
const GDScriptCompileChecker := preload("res://addons/godot_ai_chat/scripts/helper/gdscript_compile_checker.gd")


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "edit_file"
	tool_description = "Edits an existing file on disk. Support: md, txt, json, cfg, csv, glsl, gdshader, gd. Put every related change into a single `edits` call: edits apply in order and nothing is written if any of them fails. `.gd` content is compile-checked before writing — on compile errors nothing is written."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "res:// path of the text file to edit. The file must already exist."
			},
			"edits": {
				"type": "array",
				"description": "Ordered exact-string replacements. Each edit is applied to the result of the previous one.",
				"items": {
					"type": "object",
					"properties": {
						"target_string": {
							"type": "string",
							"description": "Exact text to be replaced (multi-line supported). Indentation must match, and it must occur exactly once in the file."
						},
						"replace": {
							"type": "string",
							"description": "Replacement text. Use an empty string to delete the matched text."
						}
					},
					"required": ["target_string", "replace"]
				}
			},
			"rewrite": {
				"type": "string",
				"description": "Optional. If provided (non-empty), the entire file is overwritten with this content and `edits` is ignored."
			},
			"skip_compile_check": {
				"type": "boolean",
				"description": "Optional. Set true to skip the GDScript compile check for `.gd` files (e.g. you are fixing a broken script in several steps, or it preloads a file that does not exist yet). Default false."
			}
		},
		"required": ["path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var path: String = String(p_args.get("path", "")).strip_edges()
	
	if path.is_empty():
		return ToolResult.fail("Error: 'path' is required.")
	if not path.begins_with("res://"):
		return ToolResult.fail("Error: Path must start with 'res://'.")
	if path.contains(".."):
		return ToolResult.fail("Error: Path traversal ('..') is not allowed.")
	if not FileAccess.file_exists(path):
		return ToolResult.fail("Error: file not found: %s (this tool only edits existing files)." % path)
	
	var blacklist_error: String = _validate_path_safety_with_allowlist(path)
	if not blacklist_error.is_empty():
		return ToolResult.fail(blacklist_error)
	
	var extension: String = path.get_extension().to_lower()
	if not EDITABLE_EXTENSIONS.has(extension):
		return ToolResult.fail(
			"Error: '.%s' is not an editable text extension. Supported: %s"
			% [extension, ", ".join(EDITABLE_EXTENSIONS)]
		)
	
	# --- 读取原始内容 ---
	var read_file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if read_file == null:
		return ToolResult.fail("Error: failed to open file: %d" % FileAccess.get_open_error())
	var raw_text: String = read_file.get_as_text()
	read_file.close()
	
	# --- 规范化（BOM + 行尾）---
	var has_bom: bool = raw_text.begins_with("\uFEFF")
	var working_text: String = raw_text.trim_prefix("\uFEFF")
	var uses_crlf: bool = working_text.contains("\r\n")
	working_text = working_text.replace("\r\n", "\n")
	
	# --- 生成新内容 ---
	var new_text: String = working_text
	var applied: Array[String] = []
	var rewrite_value: Variant = p_args.get("rewrite", null)
	
	if rewrite_value is String:
		var rewrite_text: String = String(rewrite_value).replace("\r\n", "\n")
		if rewrite_text.is_empty():
			return ToolResult.fail("Error: 'rewrite' is empty. Use 'edits' with an empty 'replace' to delete content.")
		new_text = rewrite_text
		applied.append("rewrite: whole file replaced (%d chars)" % new_text.length())
	else:
		var edits_value: Variant = p_args.get("edits", [])
		if not (edits_value is Array) or (edits_value as Array).is_empty():
			return ToolResult.fail("Error: provide either a non-empty 'edits' array or a non-empty 'rewrite' string.")
		
		var edit_list: Array = edits_value
		var edit_index: int = 0
		
		for raw_edit: Variant in edit_list:
			edit_index += 1
			if not (raw_edit is Dictionary):
				return ToolResult.fail("Error: edit #%d is not an object." % edit_index)
			
			var edit: Dictionary = raw_edit
			var target_string: String = String(edit.get("target_string", "")).replace("\r\n", "\n")
			# 局部变量不能叫 replace —— 会遮蔽 String.replace() 触发 SHADOWED_GLOBAL_IDENTIFIER
			var replace_text: String = String(edit.get("replace", "")).replace("\r\n", "\n")
			
			if target_string.is_empty():
				return ToolResult.fail(
					"Error: edit #%d has an empty 'target_string'. Keys are 'target_string' (text to be replaced) and 'replace' (replacement text)."
					% edit_index
				)
			
			var occurrences: int = new_text.count(target_string)
			if occurrences == 0:
				return ToolResult.fail(
					"Error: edit #%d: 'target_string' not found. No changes were written (file unchanged).\n"
					% edit_index
					+ _build_miss_hint(new_text, target_string)
				)
			
			if occurrences > 1:
				return ToolResult.fail(
					"Error: edit #%d: 'target_string' occurs %d times and must be unique. " % [edit_index, occurrences]
					+ "Add surrounding context (neighbouring lines, indentation) so it matches exactly one place. "
					+ "No changes were written."
				)
			
			new_text = new_text.replace(target_string, replace_text)
			applied.append(
				"edit #%d: replaced 1 occurrence (%d -> %d chars)"
				% [edit_index, target_string.length(), replace_text.length()]
			)
	
	if new_text == working_text:
		return ToolResult.ok("No change: content is identical. %s" % path)
	
	# --- .gd 静态编译检查：在写回之前做，失败则文件保持原状 ---
	var compile_note: String = ""
	if extension == "gd":
		if bool(p_args.get("skip_compile_check", false)):
			compile_note = "\nCompile check: skipped by request (`skip_compile_check = true`)."
		else:
			var outcome: GDScriptCompileChecker.Outcome = GDScriptCompileChecker.check(new_text, path)
			if not outcome.is_passed:
				return ToolResult.fail(GDScriptCompileChecker.format_failure(outcome, path, "modified"))
			compile_note = "\n" + GDScriptCompileChecker.format_pass_note(outcome)
	
	# --- 写回（恢复行尾风格与 BOM）---
	if uses_crlf:
		new_text = new_text.replace("\n", "\r\n")
	if has_bom:
		new_text = "\uFEFF" + new_text
	
	var write_file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if write_file == null:
		return ToolResult.fail("Error: failed to open file for writing: %d" % FileAccess.get_open_error())
	write_file.store_string(new_text)
	write_file.close()
	
	if extension == "glsl":
		ToolBox.reimport_editor_file(path)
	else:
		ToolBox.update_editor_filesystem(path)
	
	return ToolResult.ok(
		"Edited %s\n%s\nLine count: %d -> %d%s"
		% [path, "\n".join(applied), working_text.count("\n") + 1, new_text.count("\n") + 1, compile_note]
	)


# --- Private Functions ---

# 黑名单校验；EXTRA_WRITE_ALLOWLIST 中的前缀可豁免。
func _validate_path_safety_with_allowlist(p_path: String) -> String:
	var normalized: String = p_path.replace("\\", "/")
	for prefix: String in EXTRA_WRITE_ALLOWLIST:
		if normalized.begins_with(prefix.replace("\\", "/")):
			return ""
	return validate_path_safety(p_path)


# 构建未命中诊断：用 target_string 的首个有效行做探针，忽略缩进逐行比对，
# 用于区分「缩进 / tab 与空格不符」与「文件内容已变」这两种完全不同的补救方式
func _build_miss_hint(p_text: String, p_target: String) -> String:
	var probe: String = _extract_probe_line(p_target)
	if probe.length() < MIN_PROBE_CHARS:
		return "Re-read the file and copy the exact text, including indentation."
	
	var exact: Array[int] = _find_probe_lines(p_text, probe, true)
	if not exact.is_empty():
		return "Re-read the file and copy the exact text, including indentation. (Its first line matches %s exactly after trimming — most likely a leading indentation / tab-vs-space difference.)" % _format_line_list(exact)
	
	var partial: Array[int] = _find_probe_lines(p_text, probe, false)
	if not partial.is_empty():
		return "Re-read the file and copy the exact text, including indentation. (No exact match; the closest lines are %s — the file content may have changed since you read it.)" % _format_line_list(partial)
	
	return "Re-read the file and copy the exact text, including indentation. (No line resembles its first line — the file content may have changed since you read it.)"


# 取 target_string 中第一个非空行作为探针（去掉缩进）
func _extract_probe_line(p_target: String) -> String:
	for raw_line in p_target.split("\n"):
		var line: String = raw_line.strip_edges()
		if not line.is_empty():
			return line
	return ""


# 按行查找与探针匹配的行号（1-based，最多 MAX_MISS_HINTS 个）
# [param p_exact_only]: true 只比对 trim 后完全相等的行；false 时额外收集包含关系的近似行
func _find_probe_lines(p_text: String, p_probe: String, p_exact_only: bool) -> Array[int]:
	var result: Array[int] = []
	var lines: PackedStringArray = p_text.split("\n")
	
	for i in range(lines.size()):
		var line: String = lines[i].strip_edges()
		if line.is_empty():
			continue
		if line == p_probe:
			result.append(i + 1)
		elif not p_exact_only and (p_probe in line or line in p_probe):
			result.append(i + 1)
		if result.size() >= MAX_MISS_HINTS:
			break
	
	return result


# 把行号数组格式化为 "line 12, line 88" 形式
func _format_line_list(p_lines: Array[int]) -> String:
	var labels: PackedStringArray = PackedStringArray()
	for line_no in p_lines:
		labels.append("line %d" % line_no)
	return ", ".join(labels)
