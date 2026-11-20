extends AiTool

# Markdown 文档编辑工具（单处精确替换）。
#
# 设计取向：只提供最基础的编辑能力 —— 一次调用只替换一处文本，不做整篇重写。
# markdown 属于纯文档内容，不涉及项目代码与结构，因此不受管控区
# （ReadonlyZoneConfig.readonly_patterns，默认 /.git/、/.import/、/.godot/、/.addons/）限制，
# 允许在任意 res:// 路径下编辑文档。仅保留 res:// 前缀与路径穿越校验，避免写出项目目录。
# 若日后需要让文档也受管控区约束，把 validate_path_safety() 加回 execute() 即可。
#
# - 精确替换：target_string 必须逐字符匹配（含缩进），默认要求唯一命中；
#   同一段文本确实重复出现时，用 occurrence 指定第 N 处
# - 一次调用只改一处，因此不存在「多处改动只生效一部分」的问题
#
# 未命中时会用 target_string 的首个有效行做探针，返回最接近的候选行（行号 + 该行内容），
# 用于区分「缩进 / tab 与空格不符」与「文档内容已变」——两者的补救方式完全不同。
# 命中多处时会列出每处命中的行号与内容，便于补足上下文使匹配唯一。
# 写入成功后回显改动落点的周边行，用于核对确实改在了预期位置。
#
# 换行与 BOM：内部统一按 LF 匹配，写回时恢复原文档的行尾风格与 BOM，
# 因此不必关心目标文档是 LF 还是 CRLF。


# --- Constants ---

# 固定文件扩展名（本工具只处理 markdown 文档）
const VALID_EXTENSION: String = "md"

# 未命中诊断：探针行的最小长度。过短的行（如 "**"、"-"）会命中大量无关位置，没有诊断价值
const MIN_PROBE_CHARS: int = 8

# 未命中诊断：最多返回的候选行数
const MAX_MISS_HINTS: int = 3

# 命中位置诊断：最多列出的命中位置数
const MAX_HIT_HINTS: int = 5

# 行内容预览的最大字符数（所有行号回显统一使用）
const MAX_LINE_PREVIEW_CHARS: int = 100

# 改动落点回显：改动区间前后各保留的上下文行数
const CONTEXT_LINES: int = 2

# 改动落点回显：单次最多展示的行数（超出则省略中间部分）
const MAX_CONTEXT_LINES: int = 12


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "edit_markdown"
	tool_description = "Edits one exact-text location in an existing markdown (`.md`) document on disk."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "res:// path of the `.md` document to edit. The file must already exist."
			},
			"target_string": {
				"type": "string",
				"description": "Exact text to be replaced (multi-line supported). Indentation must match, and it must occur exactly once in the document unless `occurrence` is set."
			},
			"replace": {
				"type": "string",
				"description": "Replacement text. Use an empty string to delete the matched text."
			},
			"occurrence": {
				"type": "integer",
				"description": "Optional. 1-based index of the occurrence to replace, for text that legitimately appears more than once. Default 0 = the target text must be unique."
			}
		},
		"required": ["path", "target_string", "replace"]
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
	
	# 扩展名闸门：必须在读取内容之前拦下，避免模型拿它去改代码或配置
	var extension: String = path.get_extension().to_lower()
	if extension != VALID_EXTENSION:
		return ToolResult.fail(
			"Error: this tool only edits `.%s` documents, got '.%s'." % [VALID_EXTENSION, extension]
		)
	
	# 局部变量不能叫 replace —— 会遮蔽 String.replace() 触发 SHADOWED_GLOBAL_IDENTIFIER
	var target_string: String = String(p_args.get("target_string", "")).replace("\r\n", "\n")
	var replace_text: String = String(p_args.get("replace", "")).replace("\r\n", "\n")
	var occurrence: int = int(p_args.get("occurrence", 0))
	
	if target_string.is_empty():
		return ToolResult.fail(
			"Error: 'target_string' is required — pass the exact text to be replaced. Keys are 'target_string' (text to be replaced) and 'replace' (replacement text)."
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
	
	# --- 定位命中位置 ---
	var offsets: Array[int] = _find_all_offsets(working_text, target_string)
	
	if offsets.is_empty():
		return ToolResult.fail(
			"Error: 'target_string' not found. No changes were written (document unchanged).\n"
			+ _build_miss_hint(working_text, target_string)
		)
	
	var target_offset: int = -1
	var match_note: String = ""
	
	if occurrence > 0:
		# 指定第 N 处：重复文本场景下由调用方自行确认位置
		if occurrence > offsets.size():
			return ToolResult.fail(
				"Error: 'occurrence' is %d but 'target_string' occurs only %d time(s). No changes were written.\n" % [occurrence, offsets.size()]
				+ _build_hit_list(working_text, offsets)
			)
		
		target_offset = offsets[occurrence - 1]
		match_note = "replaced occurrence %d of %d (%d -> %d chars)" % [
			occurrence, offsets.size(), target_string.length(), replace_text.length()
		]
	else:
		# 默认：必须唯一命中，否则无法确定该改哪一处
		if offsets.size() > 1:
			return ToolResult.fail(
				"Error: 'target_string' occurs %d times and must be unique. " % offsets.size()
				+ "Add surrounding context (neighbouring lines, indentation) so it matches exactly one place, "
				+ "or set 'occurrence' to pick one of them. No changes were written.\n"
				+ _build_hit_list(working_text, offsets)
			)
		
		target_offset = offsets[0]
		match_note = "replaced 1 occurrence (%d -> %d chars)" % [target_string.length(), replace_text.length()]
	
	var new_text: String = _replace_at(working_text, target_offset, target_string.length(), replace_text)
	
	if new_text == working_text:
		return ToolResult.ok("No change: content is identical. %s" % path)
	
	# 落点片段必须在恢复 CRLF / BOM 之前生成，否则行尾的 \r 会混进回显
	var context_note: String = _describe_change(new_text, target_offset, replace_text)
	
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
	
	ToolBox.update_editor_filesystem(path)
	
	return ToolResult.ok(
		"Edited %s\n%s\n%s\nLine count: %d -> %d"
		% [path, match_note, context_note, working_text.count("\n") + 1, new_text.count("\n") + 1]
	)


# --- Private Functions ---

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
# [param p_text]: 用于计算行号的文本（改动之前的文本）
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
# 用于区分「缩进 / tab 与空格不符」与「文档内容已变」这两种完全不同的补救方式。
# 候选行会带上行内容，模型无需再读一次文档就能定位。
func _build_miss_hint(p_text: String, p_target: String) -> String:
	var probe: String = _extract_probe_line(p_target)
	if probe.length() < MIN_PROBE_CHARS:
		return "Re-read the document and copy the exact text, including indentation."
	
	var exact: Array[int] = _find_probe_lines(p_text, probe, true)
	if not exact.is_empty():
		return (
			"Re-read the document and copy the exact text, including indentation. "
			+ "(Its first line matches these lines exactly after trimming — most likely a leading indentation / tab-vs-space difference.)\n"
			+ _format_probe_hits(p_text, exact)
		)
	
	var partial: Array[int] = _find_probe_lines(p_text, probe, false)
	if not partial.is_empty():
		return (
			"Re-read the document and copy the exact text, including indentation. "
			+ "(No exact match; these lines are the closest ones — the document content may have changed since you read it.)\n"
			+ _format_probe_hits(p_text, partial)
		)
	
	return "Re-read the document and copy the exact text, including indentation. (No line resembles its first line — the document content may have changed since you read it.)"


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
