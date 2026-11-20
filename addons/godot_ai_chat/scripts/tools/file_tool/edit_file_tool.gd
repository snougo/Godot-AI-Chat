extends AiTool

# 文本文件编辑工具（精确替换）。
#
# 用途：直接对磁盘上已存在的文本文件做局部修改，无需经过脚本编辑器。
# - 精确替换：target_string 必须逐字符匹配（含缩进）。默认要求在文件中唯一命中；
#   同一段文本确实重复出现时，可用 occurrence 指定第 N 处，或用 replace_all 批量替换
# - 只做局部替换：本工具不提供整文件重写，需要覆盖整个文件时用 rewrite_file
# - 一次调用的 edits 是原子的：任一 edit 未命中 / 冲突 / 编译失败，都不会写盘
#
# 未命中时会用 target_string 的首个有效行做探针，返回最接近的候选行（行号 + 该行内容），
# 用于区分「缩进 / tab 与空格不符」与「文件内容已变」——两者的补救方式完全不同。
# 命中多处时会列出每处命中的行号与内容，便于补足上下文使匹配唯一。
# 写入成功后回显改动落点的周边行，用于核对确实改在了预期位置
# （target_string 恰好唯一、但唯一在错误位置时，没有这段回显就无从察觉）。
#
# 路径安全：
# 路径关卡：ReadonlyZoneConfig.readonly_patterns 命中的管控区一律禁写
#   （默认 /.git/、/.import/、/.godot/、/.addons/）
# - 豁免前缀：ReadonlyZoneConfig.extra_write_allowlist 可显式放开指定目录（默认空 = 不放开）
# - 格式关卡：ReadonlyZoneConfig.editable_text_extensions 决定哪些扩展名可改写
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

# 未命中诊断：探针行的最小长度。过短的行（如 "}"、"pass"）会命中大量无关位置，没有诊断价值
const MIN_PROBE_CHARS: int = 8

# 未命中诊断：最多返回的候选行数
const MAX_MISS_HINTS: int = 3

# 命中位置诊断：最多列出的命中 / 批量替换位置数
const MAX_HIT_HINTS: int = 5

# 行内容预览的最大字符数（所有行号回显统一使用）
const MAX_LINE_PREVIEW_CHARS: int = 100

# 改动落点回显：改动区间前后各保留的上下文行数
const CONTEXT_LINES: int = 2

# 改动落点回显：单次最多展示的行数（超出则省略中间部分）
const MAX_CONTEXT_LINES: int = 12

# GDScript 静态编译检查器（仅对 .gd 生效）
const GDScriptCompileChecker := preload("res://addons/godot_ai_chat/scripts/helper/gdscript_compile_checker.gd")


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "edit_file"
	tool_description = "Edits exact-text locations in an existing file on disk. Support: %s. This tool only does targeted replacements, use `rewrite_file` to replace the whole file. Put every related change into a single `edits` call: edits apply in order and nothing is written if any of them fails. `.gd` content is compile-checked before writing — on compile errors nothing is written." % ReadonlyZoneConfig.get_config().get_editable_extensions_text()


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
							"description": "Exact text to be replaced (multi-line supported). Indentation must match, and it must occur exactly once in the file unless `occurrence` or `replace_all` is set."
						},
						"replace": {
							"type": "string",
							"description": "Replacement text. Use an empty string to delete the matched text."
						},
						"occurrence": {
							"type": "integer",
							"description": "Optional. 1-based index of the occurrence to replace, for text that legitimately appears more than once. Cannot be combined with `replace_all`."
						},
						"replace_all": {
							"type": "boolean",
							"description": "Optional. Replace every occurrence of `target_string`. Cannot be combined with `occurrence`. Default false."
						}
					},
					"required": ["target_string", "replace"]
				}
			},
			"skip_compile_check": {
				"type": "boolean",
				"description": "Optional. Set true to skip the GDScript compile check for `.gd` files (e.g. you are fixing a broken script in several steps, or it preloads a file that does not exist yet). Default false."
			}
		},
		"required": ["path", "edits"]
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
	
	# 路径关卡（管控区 + 豁免前缀）与格式关卡（可写扩展名）统一由配置资源驱动
	var safety_err: String = validate_editable_path(path)
	if not safety_err.is_empty():
		return ToolResult.fail(safety_err)
	
	var extension: String = path.get_extension().to_lower()
	
	# --- 参数校验：本工具只做局部替换，整文件覆盖由 rewrite_file 负责 ---
	var edits_value: Variant = p_args.get("edits", [])
	var edit_list: Array = []
	if edits_value is Array:
		edit_list = edits_value
	
	if edit_list.is_empty():
		return ToolResult.fail(
			"Error: 'edits' must be a non-empty array of replacements. "
			+ "To replace the whole file, use `rewrite_file` instead."
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
	
	# --- 生成新内容（任一条失败都不写盘）---
	var new_text: String = working_text
	var applied: Array[String] = []
	var edit_index: int = 0
	
	for raw_edit: Variant in edit_list:
		edit_index += 1
		var outcome: Dictionary = _apply_single_edit(new_text, raw_edit, edit_index)
		
		if not bool(outcome.get("ok", false)):
			return ToolResult.fail(String(outcome.get("error", "Error: edit #%d failed." % edit_index)))
		
		new_text = String(outcome.get("text", new_text))
		applied.append(String(outcome.get("note", "")))
	
	# 多处 edit 顺序应用时，回显的行号是各 edit 应用时刻的行号，最终文件中会整体偏移
	var line_note: String = ""
	if edit_list.size() > 1:
		line_note = "\n(line numbers above are as of each edit's own moment; earlier edits shift later lines)"
	
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
		if extension == "gd":
			ToolBox.sync_open_scripts_after_disk_write(path)
		if extension == "gdshader":
			ToolBox.sync_shader_after_disk_write(path)
	
	return ToolResult.ok(
		"Edited %s\n%s\nLine count: %d -> %d%s%s"
		% [path, "\n\n".join(applied), working_text.count("\n") + 1, new_text.count("\n") + 1, line_note, compile_note]
	)


# --- Private Functions ---

# 应用单条 edit
# [param p_text]: 当前文本（已应用前面所有 edit 的结果）
# [param p_edit]: 单条 edit 的参数对象（Variant，需为 Dictionary）
# [param p_index]: edit 的 1-based 序号，仅用于报错信息
# 返回: { "ok": true, "text": String, "note": String } 或 { "ok": false, "error": String }
func _apply_single_edit(p_text: String, p_edit: Variant, p_index: int) -> Dictionary:
	if not (p_edit is Dictionary):
		return {"ok": false, "error": "Error: edit #%d is not an object." % p_index}
	
	var edit: Dictionary = p_edit
	var target_string: String = String(edit.get("target_string", "")).replace("\r\n", "\n")
	# 局部变量不能叫 replace —— 会遮蔽 String.replace() 触发 SHADOWED_GLOBAL_IDENTIFIER
	var replace_text: String = String(edit.get("replace", "")).replace("\r\n", "\n")
	
	if target_string.is_empty():
		return {
			"ok": false,
			"error": "Error: edit #%d has an empty 'target_string'. Keys are 'target_string' (text to be replaced) and 'replace' (replacement text)." % p_index
		}
	
	var replace_all: bool = bool(edit.get("replace_all", false))
	var occurrence: int = int(edit.get("occurrence", 0))
	
	if replace_all and occurrence > 0:
		return {
			"ok": false,
			"error": "Error: edit #%d sets both 'replace_all' and 'occurrence' (%d). Use only one of them. No changes were written." % [p_index, occurrence]
		}
	
	var offsets: Array[int] = _find_all_offsets(p_text, target_string)
	
	if offsets.is_empty():
		return {
			"ok": false,
			"error": "Error: edit #%d: 'target_string' not found. No changes were written (file unchanged).\n" % p_index
			+ _build_miss_hint(p_text, target_string)
		}
	
	# --- 批量替换：所有出现位置一起换 ---
	if replace_all:
		var bulk_text: String = p_text
		# 从后往前替换，避免前面的替换改变后面命中位置的偏移
		for i in range(offsets.size() - 1, -1, -1):
			bulk_text = _replace_at(bulk_text, offsets[i], target_string.length(), replace_text)
		
		var bulk_note: String = "edit #%d: replaced all %d occurrences (%d -> %d chars each)" % [
			p_index, offsets.size(), target_string.length(), replace_text.length()
		]
		bulk_note += "\nAll replaced positions (line numbers as of before this edit):\n" + _build_hit_list(p_text, offsets)
		return {"ok": true, "text": bulk_text, "note": bulk_note}
	
	# --- 指定第 N 处出现 ---
	if occurrence > 0:
		if occurrence > offsets.size():
			return {
				"ok": false,
				"error": "Error: edit #%d: 'occurrence' is %d but 'target_string' occurs only %d time(s). No changes were written.\n" % [p_index, occurrence, offsets.size()]
				+ _build_hit_list(p_text, offsets)
			}
		
		var picked_offset: int = offsets[occurrence - 1]
		var picked_text: String = _replace_at(p_text, picked_offset, target_string.length(), replace_text)
		var picked_note: String = "edit #%d: replaced occurrence %d of %d (%d -> %d chars)" % [
			p_index, occurrence, offsets.size(), target_string.length(), replace_text.length()
		]
		picked_note += "\n" + _describe_change(picked_text, picked_offset, replace_text)
		return {"ok": true, "text": picked_text, "note": picked_note}
	
	# --- 默认：必须唯一命中 ---
	if offsets.size() > 1:
		return {
			"ok": false,
			"error": "Error: edit #%d: 'target_string' occurs %d times and must be unique. " % [p_index, offsets.size()]
			+ "Add surrounding context (neighbouring lines, indentation) so it matches exactly one place, "
			+ "or set 'occurrence' to pick one of them, or 'replace_all' to change every one. No changes were written.\n"
			+ _build_hit_list(p_text, offsets)
		}
	
	var single_offset: int = offsets[0]
	var single_text: String = _replace_at(p_text, single_offset, target_string.length(), replace_text)
	var single_note: String = "edit #%d: replaced 1 occurrence (%d -> %d chars)" % [
		p_index, target_string.length(), replace_text.length()
	]
	single_note += "\n" + _describe_change(single_text, single_offset, replace_text)
	return {"ok": true, "text": single_text, "note": single_note}


# 在指定偏移处把定长片段替换为新内容
func _replace_at(p_text: String, p_offset: int, p_target_length: int, p_replace_text: String) -> String:
	return p_text.substr(0, p_offset) + p_replace_text + p_text.substr(p_offset + p_target_length)


# 找出 target_string 在文本中的所有非重叠起始偏移（与 String.count() 的口径一致）
func _find_all_offsets(p_text: String, p_target: String) -> Array[int]:
	var offsets: Array[int] = []
	if p_target.is_empty():
		return offsets
	
	var search_from: int = 0
	while true:
		var found: int = p_text.find(p_target, search_from)
		if found < 0:
			break
		offsets.append(found)
		search_from = found + p_target.length()
	
	return offsets


# 列出每处命中的「行号 + 该行内容」。
# 命中行内容彼此相同（如重名的标题）时，额外补上该行之前最近的标题 / 非空行，
# 否则同名的多处根本区分不开。
# [param p_text]: 用于计算行号的文本（通常是应用该 edit 之前的文本）
# [param p_offsets]: 命中位置的起始偏移数组
func _build_hit_list(p_text: String, p_offsets: Array[int]) -> String:
	var lines: PackedStringArray = p_text.split("\n")
	var show_count: int = mini(MAX_HIT_HINTS, p_offsets.size())
	
	var line_indexes: Array[int] = []
	var first_texts: Array[String] = []
	
	for i in range(show_count):
		var line_index: int = _offset_to_line_index(p_text, p_offsets[i])
		line_indexes.append(line_index)
		first_texts.append(lines[line_index].strip_edges())
	
	var needs_context: bool = _has_duplicate_strings(first_texts)
	var entries: PackedStringArray = PackedStringArray()
	
	for i in range(show_count):
		var index: int = line_indexes[i]
		var entry: String = _format_numbered_line(index, lines[index])
		if needs_context:
			var prev_text: String = _find_prev_nonempty_line(lines, index)
			if not prev_text.is_empty():
				entry += "   (prev non-empty line: %s)" % prev_text
		entries.append(entry)
	
	var result: String = "Matches (line | first line of the match):\n" + "\n".join(entries)
	if p_offsets.size() > show_count:
		result += "\n  … (%d more, not shown)" % (p_offsets.size() - show_count)
	
	return result


# 生成改动落点的周边片段（行号 + 内容），让模型能核对替换确实落在了预期位置
# [param p_text]: 已应用本次改动的文本
# [param p_offset]: 落点起始偏移（即替换内容在 p_text 中的起点）
# [param p_replace_text]: 替换后的文本（决定落点占用多少行）
func _describe_change(p_text: String, p_offset: int, p_replace_text: String) -> String:
	var lines: PackedStringArray = p_text.split("\n")
	var start_line: int = _offset_to_line_index(p_text, p_offset)
	var span_lines: int = p_replace_text.count("\n")
	
	var first_line: int = maxi(0, start_line - CONTEXT_LINES)
	var last_line: int = mini(lines.size() - 1, start_line + span_lines + CONTEXT_LINES)
	
	return "After this edit:\n" + _format_region(lines, first_line, last_line)


# 把 [p_first, p_last]（0-based、含端点）的行渲染为带行号的片段。
# 总行数超过 MAX_CONTEXT_LINES 时省略中间部分，避免一次回显上百行。
func _format_region(p_lines: PackedStringArray, p_first: int, p_last: int) -> String:
	var total: int = p_last - p_first + 1
	if total <= 0:
		return ""
	
	if total <= MAX_CONTEXT_LINES:
		var all_parts: PackedStringArray = PackedStringArray()
		for i in range(p_first, p_last + 1):
			all_parts.append(_format_numbered_line(i, p_lines[i]))
		return "\n".join(all_parts)
	
	var head_count: int = (MAX_CONTEXT_LINES + 1) / 2
	var tail_count: int = MAX_CONTEXT_LINES - head_count
	var tail_start: int = p_last - tail_count + 1
	
	var parts: PackedStringArray = PackedStringArray()
	for i in range(p_first, p_first + head_count):
		parts.append(_format_numbered_line(i, p_lines[i]))
	parts.append("  … (%d lines elided)" % (total - head_count - tail_count))
	for i in range(tail_start, p_last + 1):
		parts.append(_format_numbered_line(i, p_lines[i]))
	
	return "\n".join(parts)


# 把字符偏移换算为 0-based 行索引
func _offset_to_line_index(p_text: String, p_offset: int) -> int:
	return p_text.substr(0, p_offset).count("\n")


# 数组中是否存在重复元素
func _has_duplicate_strings(p_values: Array[String]) -> bool:
	var seen: Dictionary = {}
	for value: String in p_values:
		if seen.has(value):
			return true
		seen[value] = true
	
	return false


# 向上查找最近的非空行（已去缩进、已截断），用于区分同名的多处命中
func _find_prev_nonempty_line(p_lines: PackedStringArray, p_line_index: int) -> String:
	for i in range(p_line_index - 1, -1, -1):
		var text: String = p_lines[i].strip_edges()
		if not text.is_empty():
			return _truncate_for_preview(text)
	
	return ""


# 渲染为 "行号 | 内容" 形式（行号 1-based，右对齐）
func _format_numbered_line(p_index: int, p_text: String) -> String:
	return "  %4d | %s" % [p_index + 1, _truncate_for_preview(p_text)]


# 截断过长的单行文本，避免回显时刷屏
func _truncate_for_preview(p_text: String) -> String:
	if p_text.length() > MAX_LINE_PREVIEW_CHARS:
		return p_text.substr(0, MAX_LINE_PREVIEW_CHARS) + "…"
	return p_text


# 构建未命中诊断：用 target_string 的首个有效行做探针，忽略缩进逐行比对，
# 用于区分「缩进 / tab 与空格不符」与「文件内容已变」这两种完全不同的补救方式。
# 候选行会带上行内容，模型无需再读一次文件就能定位。
func _build_miss_hint(p_text: String, p_target: String) -> String:
	var probe: String = _extract_probe_line(p_target)
	if probe.length() < MIN_PROBE_CHARS:
		return "Re-read the file and copy the exact text, including indentation."
	
	var exact: Array[int] = _find_probe_lines(p_text, probe, true)
	if not exact.is_empty():
		return (
			"Re-read the file and copy the exact text, including indentation. "
			+ "(Its first line matches these lines exactly after trimming — most likely a leading indentation / tab-vs-space difference.)\n"
			+ _format_probe_hits(p_text, exact)
		)
	
	var partial: Array[int] = _find_probe_lines(p_text, probe, false)
	if not partial.is_empty():
		return (
			"Re-read the file and copy the exact text, including indentation. "
			+ "(No exact match; these lines are the closest ones — the file content may have changed since you read it.)\n"
			+ _format_probe_hits(p_text, partial)
		)
	
	return "Re-read the file and copy the exact text, including indentation. (No line resembles its first line — the file content may have changed since you read it.)"


# 把 1-based 行号数组渲染为「行号 + 行内容」列表
func _format_probe_hits(p_text: String, p_line_numbers: Array[int]) -> String:
	var lines: PackedStringArray = p_text.split("\n")
	var parts: PackedStringArray = PackedStringArray()
	
	for line_no: int in p_line_numbers:
		var index: int = line_no - 1
		if index < 0 or index >= lines.size():
			continue
		parts.append(_format_numbered_line(index, lines[index]))
	
	return "\n".join(parts)


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
