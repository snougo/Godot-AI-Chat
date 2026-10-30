extends RefCounted

## Markdown 转 BBCode 转换器
##
## 纯文本处理，无任何 UI 依赖。
## 将 Markdown 文本行转换为 RichTextLabel 可用的 BBCode 格式。
## 支持：标题、粗体/斜体/粗斜体、行内代码、链接、自动链接、删除线、表格、反斜杠转义。


# --- Constants ---

const MarkdownSegment := preload("res://addons/godot_ai_chat/scripts/helper/markdown/markdown_segment.gd")

# 合法的 BBCode 标签白名单（RichTextLabel 支持的核心标签）
const BBCODE_TAGS: Array[String] = [
	"b", "i", "u", "s", "color", "font", "font_size",
	"url", "lb", "rb", "img",
	"center", "left", "right", "indent",
	"code", "highlight", "br", "p"
]

# 可被反斜杠转义的字符（对齐 CommonMark，附加表格用的 |）
const ESCAPABLE_CHARS: String = "\\`*_~[]()<>#-+.!|"

# 段落实体类型（MarkdownSegment.Kind 的短名，供本文件与渲染层引用）
const SEGMENT_PLAIN: MarkdownSegment.Kind = MarkdownSegment.Kind.PLAIN
const SEGMENT_CODE: MarkdownSegment.Kind = MarkdownSegment.Kind.CODE


# --- Public Static Functions ---

## 把表格行拆成纯文本单元格（处理 \| 转义与反引号代码段内的 |）
## [param p_line]: 表格行文本，如 "| a | b |"
static func split_table_row(p_line: String) -> Array[String]:
	var row: String = p_line.strip_edges()
	if row.begins_with("|"):
		row = row.substr(1)
	# 结尾的 | 是行边界；但 "\|" 是被转义的字面竖线，不能吃掉
	if row.ends_with("|") and not row.ends_with("\\|"):
		row = row.left(-1)
	
	var cells: Array[String] = []
	var current: String = ""
	
	# 0 = 不在代码段内；>0 = 当前代码段的定界符长度
	# [为什么记长度] 三个反引号是"长度 3 的定界符"，不是三次独立翻转；
	# 只有长度相同的另一段反引号才能闭合它（与 CommonMark 一致）。
	var code_run: int = 0
	
	var i: int = 0
	while i < row.length():
		var ch: String = row[i]
		
		if ch == "`":
			var run: int = 1
			while i + run < row.length() and row[i + run] == "`":
				run += 1
			if code_run == 0:
				code_run = run
			elif run == code_run:
				code_run = 0
			current += row.substr(i, run)
			i += run
			continue
		
		# 代码段内的 | 与 \ 都是字面内容，不参与分列与转义
		if code_run == 0 and ch == "\\" and i + 1 < row.length() and row[i + 1] == "|":
			current += "|"
			i += 2
			continue
		
		if code_run == 0 and ch == "|":
			cells.append(current.strip_edges())
			current = ""
			i += 1
			continue
		
		current += ch
		i += 1
	
	cells.append(current.strip_edges())
	return cells


## 判断一行是否为表格的分隔行（表头与数据行之间的 |---|---|）
## 要求：至少含一个 |，且每个非空单元格只由 0~2 个 : 与 1 个以上 - 组成。
## 这样普通的 --- 或 "a | b" 不会被误判。
static func is_table_separator(p_line: String) -> bool:
	var text: String = p_line.strip_edges()
	if not text.contains("|"):
		return false
	
	var has_cell: bool = false
	
	for cell_text: String in split_table_row(text):
		var trimmed: String = cell_text.strip_edges()
		if trimmed.is_empty():
			continue
		
		var dashes: String = trimmed.trim_prefix(":").trim_suffix(":")
		if dashes.is_empty() or dashes.count("-") != dashes.length():
			return false
		
		has_cell = true
	
	return has_cell


## 解析分隔行里每列的对齐方式：":---" 左、"---:" 右、":---:" 居中
## [param p_line]: 分隔行，如 "|:---|:---:|---:|"
static func parse_table_alignments(p_line: String) -> Array[String]:
	var aligns: Array[String] = []
	
	for cell_text: String in split_table_row(p_line):
		var trimmed: String = cell_text.strip_edges()
		if trimmed.begins_with(":") and trimmed.ends_with(":"):
			aligns.append("center")
		elif trimmed.ends_with(":"):
			aligns.append("right")
		else:
			aligns.append("left")
	
	return aligns


## 把一段行内 Markdown 转成 segments
## [param p_palette]: 渲染配色
static func convert_inline_to_segments(p_text: String, p_palette: MarkdownPalette) -> Array[MarkdownSegment]:
	return _convert_inline_to_segments(p_text, p_palette)


static func convert_line_to_segments(p_text: String, p_palette: MarkdownPalette) -> Array[MarkdownSegment]:
	var content: String = p_text.trim_suffix("\n")
	
	var heading_level: int = 0
	for level in range(1, 7):
		var prefix: String = "#".repeat(level) + " "
		if content.begins_with(prefix):
			heading_level = level
			break
	
	if heading_level > 0:
		var heading_text: String = content.substr(heading_level + 1).strip_edges()
		var inner_segments: Array[MarkdownSegment] = _convert_inline_to_segments(heading_text, p_palette)
		var sizes: Array[int] = [28, 24, 20, 18, 16, 14]
		var result: Array[MarkdownSegment] = []
		result.append(_seg(SEGMENT_PLAIN, "[font_size=%d][b][color=#%s]" % [
				sizes[heading_level - 1], p_palette.heading.to_html(false),
		]))
		result.append_array(inner_segments)
		result.append(_seg(SEGMENT_PLAIN, "[/color][/b][/font_size]\n"))
		return result
	
	var segments: Array[MarkdownSegment] = _convert_inline_to_segments(content, p_palette)
	if not content.is_empty():
		segments.append(_seg(SEGMENT_PLAIN, "\n"))
	
	return segments


# --- Private Static Functions ---

# 检测 p_text 在 p_idx 位置是否是一个合法的 BBCode 标签
# 返回标签完整长度（含方括号），不是标签则返回 0
static func _match_bbcode_tag(p_text: String, p_idx: int) -> int:
	var remaining: int = p_text.length() - p_idx
	if remaining < 3 or p_text[p_idx] != "[":
		return 0
	
	var tag_start: int = p_idx + 1
	var is_closing: bool = p_text[tag_start] == "/"
	if is_closing:
		tag_start += 1
	
	var tag_end: int = tag_start
	while tag_end < p_text.length():
		var ch: String = p_text[tag_end]
		if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z"):
			tag_end += 1
		else:
			break
	
	if tag_end == tag_start:
		return 0
	
	var tag_name: String = p_text.substr(tag_start, tag_end - tag_start).to_lower()
	if tag_name not in BBCODE_TAGS:
		return 0
	
	var pos: int = tag_end
	var max_search: int = mini(pos + 100, p_text.length())
	while pos < max_search and p_text[pos] != "]":
		pos += 1
	
	if pos >= max_search or p_text[pos] != "]":
		return 0
	
	return pos - p_idx + 1


# 判断 p_text 中 p_idx 位置字符是否被反斜杠转义（前面有奇数个连续反斜杠）
static func _is_escaped_at(p_text: String, p_idx: int) -> bool:
	var count: int = 0
	var k: int = p_idx - 1
	
	while k >= 0 and p_text[k] == "\\":
		count += 1
		k -= 1
	
	return count % 2 == 1


# 查找 p_needle 在 p_text 中 p_from 之后首次「未被转义」出现的位置，找不到返回 -1
static func _find_unescaped(p_text: String, p_needle: String, p_from: int) -> int:
	var pos: int = p_from
	
	while pos != -1:
		pos = p_text.find(p_needle, pos)
		if pos == -1:
			return -1
		if not _is_escaped_at(p_text, pos):
			return pos
		pos += 1
	
	return -1


# 查找斜体的闭合 *，跳过中间的 **...** 对，并跳过被反斜杠转义的 *
static func _find_italic_end(p_text: String, p_start: int) -> int:
	var j: int = p_start + 1
	
	while j < p_text.length():
		if p_text[j] == "*":
			# 跳过被反斜杠转义的星号
			if _is_escaped_at(p_text, j):
				j += 1
				continue
			if j + 1 < p_text.length() and p_text[j + 1] == "*":
				var bold_end: int = _find_unescaped(p_text, "**", j + 2)
				if bold_end != -1:
					j = bold_end + 2
					continue
				else:
					return -1
			else:
				return j
		j += 1
	
	return -1


static func _convert_inline_to_segments(p_text: String, p_palette: MarkdownPalette) -> Array[MarkdownSegment]:
	var segments: Array[MarkdownSegment] = []
	var i: int = 0
	var len: int = p_text.length()
	
	while i < len:
		var c: String = p_text[i]
		
		match c:
			"*":
				if i + 2 < len and p_text[i + 1] == "*" and p_text[i + 2] == "*":
					var end: int = _find_unescaped(p_text, "***", i + 3)
					if end != -1:
						var inner: String = p_text.substr(i + 3, end - i - 3)
						var inner_segments: Array[MarkdownSegment] = _convert_inline_to_segments(inner, p_palette)
						segments.append(_seg(SEGMENT_PLAIN, "[b][i][color=#%s]" % p_palette.bold_italic.to_html(false)))
						segments.append_array(inner_segments)
						segments.append(_seg(SEGMENT_PLAIN, "[/color][/i][/b]"))
						i = end + 3
						continue
				
				if i + 1 < len and p_text[i + 1] == "*":
					var end: int = _find_unescaped(p_text, "**", i + 2)
					if end != -1:
						var inner: String = p_text.substr(i + 2, end - i - 2)
						var inner_segments: Array[MarkdownSegment] = _convert_inline_to_segments(inner, p_palette)
						segments.append(_seg(SEGMENT_PLAIN, "[b][color=#%s]" % p_palette.bold.to_html(false)))
						segments.append_array(inner_segments)
						segments.append(_seg(SEGMENT_PLAIN, "[/color][/b]"))
						i = end + 2
						continue
				
				var end: int = _find_italic_end(p_text, i)
				if end != -1:
					var inner: String = p_text.substr(i + 1, end - i - 1)
					var inner_segments: Array[MarkdownSegment] = _convert_inline_to_segments(inner, p_palette)
					segments.append(_seg(SEGMENT_PLAIN, "[i][color=#%s]" % p_palette.italic.to_html(false)))
					segments.append_array(inner_segments)
					segments.append(_seg(SEGMENT_PLAIN, "[/color][/i]"))
					i = end + 1
					continue
				
				segments.append(_seg(SEGMENT_PLAIN, c))
				i += 1
			
			"`":
				var delim_len: int = 1
				while i + delim_len < len and p_text[i + delim_len] == "`":
					delim_len += 1
				
				var search_start: int = i + delim_len
				var found_end: int = -1
				var j: int = search_start
				while j < len:
					if p_text[j] == "`":
						var match_len: int = 1
						while j + match_len < len and p_text[j + match_len] == "`":
							match_len += 1
						if match_len == delim_len:
							found_end = j + delim_len - 1
							break
						j += match_len
					else:
						j += 1
				
				if found_end != -1:
					var inner: String = p_text.substr(search_start, j - search_start)
					segments.append(_seg(SEGMENT_CODE, inner))
					i = found_end + 1
					continue
				
				segments.append(_seg(SEGMENT_PLAIN, "`".repeat(delim_len)))
				i += delim_len
			
			"\\":
				# 反斜杠转义：仅当下一字符为可转义字符时消费反斜杠，否则原样输出
				if i + 1 < len and p_text[i + 1] in ESCAPABLE_CHARS:
					match p_text[i + 1]:
						"[":
							segments.append(_seg(SEGMENT_PLAIN, "[lb]"))
						"]":
							segments.append(_seg(SEGMENT_PLAIN, "[rb]"))
						_:
							segments.append(_seg(SEGMENT_PLAIN, p_text[i + 1]))
					i += 2
					continue
				segments.append(_seg(SEGMENT_PLAIN, c))
				i += 1
			
			"[":
				var close_bracket: int = p_text.find("]", i + 1)
				if close_bracket != -1 and close_bracket + 1 < len and p_text[close_bracket + 1] == "(":
					var close_paren: int = p_text.find(")", close_bracket + 2)
					if close_paren != -1:
						var link_text: String = p_text.substr(i + 1, close_bracket - i - 1)
						var link_url: String = p_text.substr(close_bracket + 2, close_paren - close_bracket - 2)
						link_url = link_url.replace("[", "[lb]").replace("]", "[rb]")
						var inner_segments: Array[MarkdownSegment] = _convert_inline_to_segments(link_text, p_palette)
						segments.append(_seg(SEGMENT_PLAIN, "[color=#%s][url=%s]" % [p_palette.link.to_html(false), link_url,]))
						segments.append_array(inner_segments)
						segments.append(_seg(SEGMENT_PLAIN, "[/url][/color]"))
						i = close_paren + 1
						continue
				
				var bbcode_len: int = _match_bbcode_tag(p_text, i)
				if bbcode_len > 0:
					segments.append(_seg(SEGMENT_PLAIN, p_text.substr(i, bbcode_len)))
					i += bbcode_len
					continue
				
				segments.append(_seg(SEGMENT_PLAIN, "[lb]"))
				i += 1
			
			"]":
				segments.append(_seg(SEGMENT_PLAIN, "[rb]"))
				i += 1
			
			"~":
				if i + 1 < len and p_text[i + 1] == "~":
					var end: int = _find_unescaped(p_text, "~~", i + 2)
					if end != -1:
						var inner: String = p_text.substr(i + 2, end - i - 2)
						var inner_segments: Array[MarkdownSegment] = _convert_inline_to_segments(inner, p_palette)
						segments.append(_seg(SEGMENT_PLAIN, "[s]"))
						segments.append_array(inner_segments)
						segments.append(_seg(SEGMENT_PLAIN, "[/s]"))
						i = end + 2
						continue
				segments.append(_seg(SEGMENT_PLAIN, c))
				i += 1
			
			"<":
				var end: int = p_text.find(">", i + 1)
				if end != -1:
					var url: String = p_text.substr(i + 1, end - i - 1)
					if url.begins_with("http://") or url.begins_with("https://") \
							or url.begins_with("ftp://") or url.begins_with("www.") \
							or ("@" in url and "." in url):
						url = url.replace("[", "[lb]").replace("]", "[rb]")
						segments.append(_seg(SEGMENT_PLAIN, "[color=#%s][url=%s]%s[/url][/color]" % [p_palette.link.to_html(false), url, url,]))
						i = end + 1
						continue
				segments.append(_seg(SEGMENT_PLAIN, c))
				i += 1
			
			_:
				var start: int = i
				# [排除表必须与上方 match 分支一一对应] 漏掉 "\\" 会让反斜杠被当成普通字符吞掉，
				# 后面的 \x 转义逻辑永远不执行（表现为 \[b\] 原样多出一个反斜杠）。
				while i < len and p_text[i] not in ["*", "`", "\\", "[", "]", "~", "<"]:
					i += 1
				if i > start:
					segments.append(_seg(SEGMENT_PLAIN, p_text.substr(start, i - start)))
	
	return segments


# 构造一个行内片段
# [为什么保留这个捷径] 下方 _convert_inline_to_segments() 有 20 余处构造点，
# 每处都写 MarkdownSegment.new(MarkdownSegment.Kind.PLAIN, ...) 会淹没解析逻辑本身。
static func _seg(p_kind: MarkdownSegment.Kind, p_content: String) -> MarkdownSegment:
	return MarkdownSegment.new(p_kind, p_content)
