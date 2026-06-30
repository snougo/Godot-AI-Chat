class_name MarkdownToBBCode
## Markdown 转 BBCode 转换器
##
## 纯文本处理，无任何 UI 依赖。
## 将 Markdown 文本行转换为 RichTextLabel 可用的 BBCode 格式。
## 支持：标题、粗体/斜体/粗斜体、行内代码、链接、自动链接、删除线、表格。

# --- Constants ---

## 合法的 BBCode 标签白名单（RichTextLabel 支持的核心标签）
const BBCODE_TAGS: Array[String] = [
	"b", "i", "u", "s", "color", "font", "font_size",
	"url", "lb", "rb", "img",
	"center", "left", "right", "indent",
	"code", "highlight", "br", "p"
]

## 段落实体类型
const SEGMENT_PLAIN: int = 0
const SEGMENT_CODE: int = 1

# --- Public Static Functions ---

## 将一行 Markdown 文本转换为 BBCode
## 支持：标题(#~######) 粗体/斜体/行内代码/链接/删除线
static func convert_line(p_text: String) -> String:
	var content: String = p_text.trim_suffix("\n")
	
	# 标题检测
	var heading_level: int = 0
	for level in range(1, 7):
		var prefix: String = "#".repeat(level) + " "
		if content.begins_with(prefix):
			heading_level = level
			break
	
	if heading_level > 0:
		var heading_text: String = content.substr(heading_level + 1).strip_edges()
		heading_text = convert_inline(heading_text)
		var sizes: Array[int] = [28, 24, 20, 18, 16, 14]
		return "[font_size=%d][b][color=#ff729c]%s[/color][/b][/font_size]\n" % [sizes[heading_level - 1], heading_text]
	
	# 普通文本：内联转换
	return convert_inline(content) + "\n"


## 将一行文本中的内联 Markdown 转换为 BBCode
## 使用 match 分派模式：按首字符路由，每种语法内联处理
static func convert_inline(p_text: String) -> String:
	var result: String = ""
	var i: int = 0
	var len: int = p_text.length()
	
	while i < len:
		var c: String = p_text[i]
		
		match c:
			"*":
				# ***bold-italic***（优先于 ** 检测）
				if i + 2 < len and p_text[i + 1] == "*" and p_text[i + 2] == "*":
					var end: int = p_text.find("***", i + 3)
					if end != -1:
						var inner: String = convert_inline(p_text.substr(i + 3, end - i - 3))
						result += "[b][i][color=#c792ea]" + inner + "[/color][/i][/b]"
						i = end + 3
						continue
				
				# **bold**
				if i + 1 < len and p_text[i + 1] == "*":
					var end: int = p_text.find("**", i + 2)
					if end != -1:
						var inner: String = convert_inline(p_text.substr(i + 2, end - i - 2))
						result += "[b][color=#94bcff]" + inner + "[/color][/b]"
						i = end + 2
						continue
				
				# *italic*
				var end: int = _find_italic_end(p_text, i)
				if end != -1:
					var inner: String = convert_inline(p_text.substr(i + 1, end - i - 1))
					result += "[i][color=#569CD6]" + inner + "[/color][/i]"
					i = end + 1
					continue
				
				result += c
				i += 1
			
			"`":
				# 统计连续反引号数量（定界符长度），支持多反引号定界
				var delim_len: int = 1
				while i + delim_len < len and p_text[i + delim_len] == "`":
					delim_len += 1
				
				# 从定界符之后开始找对应的闭合定界符
				var search_start: int = i + delim_len
				var found_end: int = -1
				var j: int = search_start
				while j < len:
					if p_text[j] == "`":
						var match_len: int = 1
						while j + match_len < len and p_text[j + match_len] == "`":
							match_len += 1
						# 找到连续 delim_len 个反引号即为闭合
						if match_len == delim_len:
							found_end = j + delim_len - 1
							break
						j += match_len
					else:
						j += 1
				
				if found_end != -1:
					var inner: String = p_text.substr(search_start, j - search_start)
					inner = inner.replace("[", "[lb]").replace("]", "[rb]")
					result += "[color=#d2cf95]" + inner + "[/color]"
					i = found_end + 1
					continue
				
				# 没有匹配的闭合，当作普通文本输出
				result += "`".repeat(delim_len)
				i += delim_len
			
			"[":
				var close_bracket: int = p_text.find("]", i + 1)
				if close_bracket != -1 and close_bracket + 1 < len and p_text[close_bracket + 1] == "(":
					var close_paren: int = p_text.find(")", close_bracket + 2)
					if close_paren != -1:
						var link_text: String = p_text.substr(i + 1, close_bracket - i - 1)
						var link_url: String = p_text.substr(close_bracket + 2, close_paren - close_bracket - 2)
						link_url = link_url.replace("[", "[lb]").replace("]", "[rb]")
						link_text = convert_inline(link_text)
						result += "[color=#B39DDB][url=" + link_url + "]" + link_text + "[/url][/color]"
						i = close_paren + 1
						continue
				
				var bbcode_len: int = _match_bbcode_tag(p_text, i)
				if bbcode_len > 0:
					result += p_text.substr(i, bbcode_len)
					i += bbcode_len
					continue
				
				result += "[lb]"
				i += 1
			
			"]":
				result += "[rb]"
				i += 1
			
			"~":
				if i + 1 < len and p_text[i + 1] == "~":
					var end: int = p_text.find("~~", i + 2)
					if end != -1:
						var inner: String = convert_inline(p_text.substr(i + 2, end - i - 2))
						result += "[s]" + inner + "[/s]"
						i = end + 2
						continue
				result += c
				i += 1
			
			"<":
				var end: int = p_text.find(">", i + 1)
				if end != -1:
					var url: String = p_text.substr(i + 1, end - i - 1)
					if url.begins_with("http://") or url.begins_with("https://") \
							or url.begins_with("ftp://") or url.begins_with("www.") \
							or ("@" in url and "." in url):
						url = url.replace("[", "[lb]").replace("]", "[rb]")
						result += "[color=#B39DDB][url=" + url + "]" + url + "[/url][/color]"
						i = end + 1
						continue
				result += c
				i += 1
			
			_:
				result += c
				i += 1
	
	return result


## 将 Markdown 表格行转换为 BBCode 表格行
## [param p_line]: 表格行文本，如 "| col1 | col2 |"
## [param p_is_header]: 是否为表头行（第一行）
## 返回: BBCode 格式的表格行
static func make_table_row(p_line: String, p_is_header: bool) -> String:
	var row: String = p_line
	if row.begins_with("|"):
		row = row.substr(1)
	if row.ends_with("|"):
		row = row.left(-1)
	
	var cells: Array[String] = []
	var current_cell: String = ""
	var in_backtick: bool = false
	var i: int = 0
	while i < row.length():
		var ch: String = row[i]
		
		if ch == "`":
			in_backtick = not in_backtick
			current_cell += ch
			i += 1
			continue
		
		if not in_backtick and ch == "\\" and i + 1 < row.length() and row[i + 1] == "|":
			current_cell += "|"
			i += 2
			continue
		
		if not in_backtick and ch == "|":
			var cell_segments: Array[Dictionary] = _convert_inline_to_segments(current_cell.strip_edges())
			var cell_bb: String = ""
			for s in cell_segments:
				if s.type == SEGMENT_PLAIN:
					cell_bb += s.content
				else:
					cell_bb += "[color=#d2cf95]" + s.content.replace("[", "[lb]").replace("]", "[rb]") + "[/color]"
			cells.append(cell_bb)
			
			current_cell = ""
			i += 1
			continue
		
		current_cell += ch
		i += 1
	
	var cell_segments: Array[Dictionary] = _convert_inline_to_segments(current_cell.strip_edges())
	var cell_bb: String = ""
	for s in cell_segments:
		if s.type == SEGMENT_PLAIN:
			cell_bb += s.content
		else:
			cell_bb += "[color=#d2cf95]" + s.content.replace("[", "[lb]").replace("]", "[rb]") + "[/color]"
	cells.append(cell_bb)
	
	var column_count: int = cells.size()
	
	if p_is_header:
		var header_cells: PackedStringArray = []
		for c in cells:
			header_cells.append("[cell bg=#2d2d5e][b]%s[/b][/cell]" % c)
		return "[table=%d]" % column_count + "".join(header_cells) + "\n"
	else:
		var data_cells: PackedStringArray = []
		for c in cells:
			data_cells.append("[cell]%s[/cell]" % c)
		return "".join(data_cells) + "\n"


static func convert_line_to_segments(p_text: String) -> Array[Dictionary]:
	var content: String = p_text.trim_suffix("\n")
	
	var heading_level: int = 0
	for level in range(1, 7):
		var prefix: String = "#".repeat(level) + " "
		if content.begins_with(prefix):
			heading_level = level
			break
	
	if heading_level > 0:
		var heading_text: String = content.substr(heading_level + 1).strip_edges()
		var inner_segments: Array[Dictionary] = _convert_inline_to_segments(heading_text)
		var sizes: Array[int] = [28, 24, 20, 18, 16, 14]
		var result: Array[Dictionary] = []
		result.append(_seg(SEGMENT_PLAIN, "[font_size=%d][b][color=#ff729c]" % sizes[heading_level - 1]))
		result.append_array(inner_segments)
		result.append(_seg(SEGMENT_PLAIN, "[/color][/b][/font_size]\n"))
		return result
	
	var segments: Array[Dictionary] = _convert_inline_to_segments(content)
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


# 查找斜体的闭合 *，跳过中间的 **...** 对
static func _find_italic_end(p_text: String, p_start: int) -> int:
	var j: int = p_start + 1
	while j < p_text.length():
		if p_text[j] == "*":
			if j + 1 < p_text.length() and p_text[j + 1] == "*":
				var bold_end: int = p_text.find("**", j + 2)
				if bold_end != -1:
					j = bold_end + 2
					continue
				else:
					return -1
			else:
				return j
		j += 1
	return -1


static func _convert_inline_to_segments(p_text: String) -> Array[Dictionary]:
	var segments: Array[Dictionary] = []
	var i: int = 0
	var len: int = p_text.length()
	
	while i < len:
		var c: String = p_text[i]
		
		match c:
			"*":
				if i + 2 < len and p_text[i + 1] == "*" and p_text[i + 2] == "*":
					var end: int = p_text.find("***", i + 3)
					if end != -1:
						var inner: String = p_text.substr(i + 3, end - i - 3)
						var inner_segments: Array[Dictionary] = _convert_inline_to_segments(inner)
						segments.append(_seg(SEGMENT_PLAIN, "[b][i][color=#c792ea]"))
						segments.append_array(inner_segments)
						segments.append(_seg(SEGMENT_PLAIN, "[/color][/i][/b]"))
						i = end + 3
						continue
				
				if i + 1 < len and p_text[i + 1] == "*":
					var end: int = p_text.find("**", i + 2)
					if end != -1:
						var inner: String = p_text.substr(i + 2, end - i - 2)
						var inner_segments: Array[Dictionary] = _convert_inline_to_segments(inner)
						segments.append(_seg(SEGMENT_PLAIN, "[b][color=#94bcff]"))
						segments.append_array(inner_segments)
						segments.append(_seg(SEGMENT_PLAIN, "[/color][/b]"))
						i = end + 2
						continue
				
				var end: int = _find_italic_end(p_text, i)
				if end != -1:
					var inner: String = p_text.substr(i + 1, end - i - 1)
					var inner_segments: Array[Dictionary] = _convert_inline_to_segments(inner)
					segments.append(_seg(SEGMENT_PLAIN, "[i][color=#569CD6]"))
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
			
			"[":
				var close_bracket: int = p_text.find("]", i + 1)
				if close_bracket != -1 and close_bracket + 1 < len and p_text[close_bracket + 1] == "(":
					var close_paren: int = p_text.find(")", close_bracket + 2)
					if close_paren != -1:
						var link_text: String = p_text.substr(i + 1, close_bracket - i - 1)
						var link_url: String = p_text.substr(close_bracket + 2, close_paren - close_bracket - 2)
						link_url = link_url.replace("[", "[lb]").replace("]", "[rb]")
						var inner_segments: Array[Dictionary] = _convert_inline_to_segments(link_text)
						segments.append(_seg(SEGMENT_PLAIN, "[color=#B39DDB][url=" + link_url + "]"))
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
					var end: int = p_text.find("~~", i + 2)
					if end != -1:
						var inner: String = p_text.substr(i + 2, end - i - 2)
						var inner_segments: Array[Dictionary] = _convert_inline_to_segments(inner)
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
						segments.append(_seg(SEGMENT_PLAIN, "[color=#B39DDB][url=" + url + "]" + url + "[/url][/color]"))
						i = end + 1
						continue
				segments.append(_seg(SEGMENT_PLAIN, c))
				i += 1
			
			_:
				var start: int = i
				while i < len and p_text[i] not in ["*", "`", "[", "]", "~", "<"]:
					i += 1
				if i > start:
					segments.append(_seg(SEGMENT_PLAIN, p_text.substr(start, i - start)))
	
	return segments


static func _seg(p_type: int, p_content: String) -> Dictionary:
	return {"type": p_type, "content": p_content}
