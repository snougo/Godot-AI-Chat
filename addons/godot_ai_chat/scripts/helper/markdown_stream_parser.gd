extends RefCounted

## 流式 Markdown 块级解析器
##
## 把流式输入切成"块"，每块用专门的信号交付；渲染层只负责"把块画出来"，
## 不再判断"这一行长什么样"。
##
## 本类负责的块：围栏代码块、表格；其余行按普通行（text_line）或空行（blank）交付。
## 行内 Markdown（粗体、行内代码、链接…）仍由 MarkdownToBBCode 处理；
## 唯一例外是表格行——它必须先按 | 切分，而切分逻辑本来就在 MarkdownToBBCode 里。
##
## 使用方式：
##   1. 连接需要的块信号
##   2. 调用 feed() 喂入流式文本
##   3. 流结束时调用 flush() 刷新残余缓冲区（同时收尾未完结的块）
##   4. 重置时调用 reset()


# --- Signals ---

## 普通段落行（原始 Markdown，含尾随换行符）
signal text_line(p_line: String)
## 空行
signal blank()
## 围栏代码块开始；[param p_lang] 为围栏后的语言标识符，可为空
signal code_start(p_lang: String)
## 围栏代码块内容行（含尾随换行符）
signal code_line(p_line: String)
## 围栏代码块结束
signal code_end()
## 表格开始；[param p_aligns] 为每列对齐方式（"left" / "center" / "right"）
signal table_start(p_columns: int, p_aligns: Array[String])
## 表格行；元素为单元格的**原始文本**（String），行内转换由渲染层负责
signal table_row(p_cells: Array)
## 表格结束
signal table_end()
## 列表项；[param p_depth] 层级（从 0 开始）、[param p_marker] 原始标记（`-` / `*` / `+` / `1.`）、
## [param p_text] 内容原文
signal list_item(p_depth: int, p_marker: String, p_text: String)
## 引用块（整块交付）；元素为去掉 `>` 后的原始行
signal quote(p_lines: PackedStringArray)
## 分隔线（--- / *** / ___）
signal rule()


# --- Enums ---

## 内部解析状态（不暴露给外部）
enum _ParseState {
	TEXT,   ## 普通文本模式
	CODE,   ## 围栏代码块模式
	TABLE,  ## 表格模式
	QUOTE,  ## 引用块模式（整块缓冲）
}


# --- Constants ---

const MarkdownToBBCode := preload("res://addons/godot_ai_chat/scripts/helper/markdown_to_bbcode.gd")


# --- Private Vars ---

# 当前解析状态
var _state: int = _ParseState.TEXT

# 不完整行的缓冲区（仅包含尚未以 \n 结尾的内容）
var _line_buffer: String = ""

# 当前围栏的长度（用于判定闭合围栏是否足够长）
var _current_fence_len: int = 0

# 当前围栏的字符类型（"`" 或 "~"）
var _fence_char: String = ""

# 围栏嵌套深度计数器（仅用于"内层围栏与外层等长"的情形）
var _nested_depth: int = 0

# 表格：待确认的首行（等下一行才能判断它是表头还是普通段落）
var _table_pending_header: Array = []
# 表格：待确认首行的原始文本（最终判定为普通段落时按原文回退）
var _table_pending_line: String = ""
# 表格：已确定的列数与每列对齐方式
var _table_columns: int = 0
var _table_aligns: Array[String] = []

# 引用块：已收集的行（去掉 > 后的原文）
var _quote_lines: PackedStringArray = PackedStringArray()

# --- 正则表达式（预编译） ---
# CommonMark 规则：
#   - 开启围栏：0-3 空格缩进 + 3+ 围栏字符 + 可选 info string（不含同种围栏字符）
#   - 闭合围栏：0-3 空格缩进 + 3+ 围栏字符 + 仅水平空白

# 反引号围栏开始行
var _re_open_backtick: RegEx = RegEx.create_from_string("^( {0,3})(`{3,})([^`]*)$")
# 反引号围栏结束行
var _re_close_backtick: RegEx = RegEx.create_from_string("^( {0,3})(`{3,})[ \\t]*$")
# 波浪线围栏开始行
var _re_open_tilde: RegEx = RegEx.create_from_string("^( {0,3})(~{3,})([^~]*)$")
# 波浪线围栏结束行
var _re_close_tilde: RegEx = RegEx.create_from_string("^( {0,3})(~{3,})[ \\t]*$")

# 列表项：缩进 + 标记 + 空白 + 内容
var _re_list_item: RegEx = RegEx.create_from_string("^([ \\t]*)([-*+]|\\d+[.)])\\s+(.*)$")
# 引用行：0-3 空格缩进 + > + 可选一个空格 + 内容
var _re_quote: RegEx = RegEx.create_from_string("^ {0,3}> ?(.*)$")
# 分隔线：同一字符（- * _）至少 3 个，中间可有空格
var _re_rule: RegEx = RegEx.create_from_string("^ {0,3}([-*_])( *\\1){2,} *$")


# --- Public Functions ---

## 重置解析器到初始状态
func reset() -> void:
	_state = _ParseState.TEXT
	_line_buffer = ""
	_current_fence_len = 0
	_fence_char = ""
	_nested_depth = 0
	_quote_lines = PackedStringArray()
	_reset_table()


## 喂入一段文本，自动提取完整行并解析
## [param p_text]: 新增的文本片段
func feed(p_text: String) -> void:
	if p_text.is_empty():
		return
	_line_buffer += p_text
	_drain_lines()


## 刷新缓冲区（流结束时必须调用）
## 将缓冲区中不完整的最后一行作为独立行处理，并收尾未完结的块。
func flush() -> void:
	if not _line_buffer.is_empty():
		var remaining: String = _line_buffer
		_line_buffer = ""
		
		# \r 兼容处理
		if remaining.ends_with("\r"):
			remaining = remaining.left(-1)
		
		if not remaining.is_empty():
			_process_line(remaining)
	
	# 收尾：单行表格、未闭合的表格、未结束的引用块
	_finish_pending_table_header()
	_close_table()
	_flush_quote()


## 查询当前是否在代码块内
func is_in_code_block() -> bool:
	return _state == _ParseState.CODE


## 获取缓冲区中尚未处理的文本（可用于 UI 预览）
func get_pending_text() -> String:
	return _line_buffer


# --- Private Functions ---

# 从缓冲区中提取并处理所有完整行
# 完整行 = 以 \n 结尾的行
func _drain_lines() -> void:
	while true:
		var nl_pos: int = _line_buffer.find("\n")
		if nl_pos == -1:
			break
		
		var line: String = _line_buffer.substr(0, nl_pos)
		_line_buffer = _line_buffer.substr(nl_pos + 1)
		
		# \r\n 兼容：移除行尾的 \r
		if line.ends_with("\r"):
			line = line.left(-1)
		
		_process_line(line)


# 处理单行文本（状态机入口）
func _process_line(p_line: String) -> void:
	match _state:
		_ParseState.TEXT:
			_process_text_line(p_line)
		_ParseState.CODE:
			_process_code_line(p_line)
		_ParseState.TABLE:
			# 表格只被"非表格行"终结；终结后当前行必须回到 TEXT 重新判定，否则会丢行
			if MarkdownToBBCode.is_table_separator(p_line):
				pass  # 表格中途的重复分隔行：忽略（与既有行为一致）
			elif _is_table_row_line(p_line):
				table_row.emit(MarkdownToBBCode.split_table_row(p_line))
			else:
				_close_table()
				_process_line(p_line)
		_ParseState.QUOTE:
			# 引用块同理：被"非引用行"终结，终结后当前行回到 TEXT 重新判定
			var quote_match: RegExMatch = _re_quote.search(p_line)
			if quote_match:
				_quote_lines.append(quote_match.get_string(1))
			else:
				_flush_quote()
				_process_line(p_line)


# 处理 TEXT 模式下的行
# 优先级：围栏 → 分隔线 → 表格 → 引用 → 列表 → 空行 → 普通文本
func _process_text_line(p_line: String) -> void:
	# 0. 缓冲中的表格首行 + 当前行不是表格行 → 按"单行表格"交付
	# [为什么不是退回段落] 原实现是"首行即开启表格、遇到非表格行就闭合"，
	# 所以单行 |a|b| 会渲染成一张单行表格（首行当表头），退回段落会破坏等价性。
	if not _table_pending_header.is_empty() and not _is_table_row_line(p_line):
		_finish_pending_table_header()
	
	# 1. 尝试匹配反引号围栏开始
	var m: RegExMatch = _re_open_backtick.search(p_line)
	var fence_char: String = ""
	var fence: String = ""
	var info: String = ""
	
	if m and not m.get_string(3).contains("`"):
		# CommonMark：反引号围栏的 info string 不能包含反引号
		fence = m.get_string(2)
		info = m.get_string(3).strip_edges()
		fence_char = "`"
	else:
		# 2. 尝试匹配波浪线围栏开始
		m = _re_open_tilde.search(p_line)
		if m and not m.get_string(3).contains("~"):
			fence = m.get_string(2)
			info = m.get_string(3).strip_edges()
			fence_char = "~"
	
	if not fence_char.is_empty():
		_enter_code_block(fence, info, fence_char)
		return
	
	# 3. 分隔线（必须早于列表：`- - -` 两者都匹配，CommonMark 里算分隔线）
	if _re_rule.search(p_line):
		rule.emit()
		return
	
	# 4. 表格行（含分隔行）
	if _is_table_row_line(p_line):
		_handle_table_row_line(p_line)
		return
	
	# 5. 引用行 → 进入引用块状态
	var quote_match: RegExMatch = _re_quote.search(p_line)
	if quote_match:
		_state = _ParseState.QUOTE
		_quote_lines = PackedStringArray([quote_match.get_string(1)])
		return
	
	# 6. 列表项
	var list_match: RegExMatch = _re_list_item.search(p_line)
	if list_match:
		var indent: String = list_match.get_string(1)
		# 缩进层级：tab 算一层，2 空格算一层
		var depth: int = indent.count("\t") + floori(indent.count(" ") / 2.0)
		list_item.emit(depth, list_match.get_string(2), list_match.get_string(3))
		return
	
	# 7. 空行
	if p_line.strip_edges().is_empty():
		blank.emit()
		return
	
	# 8. 普通文本行
	text_line.emit(p_line + "\n")


# 处理 CODE 模式下的行
func _process_code_line(p_line: String) -> void:
	# 1 检测"与开启围栏等长的带 info 围栏行" → 深度 +1，作为内容输出
	# [为什么必须要求等长] 只有长度相同（无法靠长度区分开/闭）时才需要深度计数兜底。
	# 若内层围栏更短（外层 ````、内层 ```），长度规则本身就能区分，
	# 此时再计深度，外层真正的闭合围栏会被误判成"内层闭合"，代码块就永不结束。
	if _is_fenced_open_with_info(p_line, _fence_char) \
			and _fence_run_length(p_line, _fence_char) == _current_fence_len:
		_nested_depth += 1
		code_line.emit(p_line + "\n")
		return
	
	# 2 检测闭合围栏
	var m: RegExMatch
	if _fence_char == "`":
		m = _re_close_backtick.search(p_line)
	else:
		m = _re_close_tilde.search(p_line)
	
	if m:
		var fence: String = m.get_string(2)
		if fence.length() >= _current_fence_len:
			if _nested_depth > 0:
				# 有等长嵌套 → 递减深度，行作为内容输出
				_nested_depth -= 1
				code_line.emit(p_line + "\n")
				return
			else:
				# 无嵌套 → 正常退出代码块
				_exit_code_block()
				return
	
	# 3 其他情况 → 代码内容
	code_line.emit(p_line + "\n")


# 进入代码块状态
func _enter_code_block(p_fence: String, p_lang: String, p_fence_char: String) -> void:
	_state = _ParseState.CODE
	_current_fence_len = p_fence.length()
	_fence_char = p_fence_char
	_nested_depth = 0
	code_start.emit(p_lang)


# 退出代码块状态
func _exit_code_block() -> void:
	_state = _ParseState.TEXT
	_current_fence_len = 0
	_fence_char = ""
	_nested_depth = 0
	code_end.emit()


# 检测当前行是否为"有语言标识符的围栏开始行"
func _is_fenced_open_with_info(p_line: String, p_fence_char: String) -> bool:
	var regex: RegEx = _re_open_backtick if p_fence_char == "`" else _re_open_tilde
	var m: RegExMatch = regex.search(p_line)
	if m:
		var info: String = m.get_string(3).strip_edges()
		return not info.is_empty()
	return false


# 统计行首同字符围栏的连续个数（允许前置空格）；不是围栏行时返回 0
func _fence_run_length(p_line: String, p_fence_char: String) -> int:
	var text: String = p_line.strip_edges()
	return text.length() - text.lstrip(p_fence_char).length()


# 该行是否为表格行（行首为 |，宽松判定：避免正文中出现的 | 被误判）
static func _is_table_row_line(p_line: String) -> bool:
	return p_line.strip_edges().begins_with("|")


# 表格行：首行先缓冲（等下一行确认结构），分隔行只用来确定对齐
func _handle_table_row_line(p_line: String) -> void:
	# 分隔行不输出，只用于确定对齐；没有缓冲首行时是孤立分隔行，直接丢弃
	if MarkdownToBBCode.is_table_separator(p_line):
		if _table_pending_header.is_empty():
			return
		_start_table(MarkdownToBBCode.parse_table_alignments(p_line))
		return
	
	var cells: Array = MarkdownToBBCode.split_table_row(p_line)
	
	# 第一行：先缓冲，等下一行判断它是表头还是普通段落
	if _table_pending_header.is_empty():
		_table_pending_header = cells
		_table_pending_line = p_line
		return
	
	# 缓冲的首行 + 当前行，且中间没有分隔行 → 兼容"缺分隔行"的表格
	var aligns: Array[String] = []
	_start_table(aligns)
	table_row.emit(cells)


# 用缓冲的首行开启表格；[param p_aligns] 不足列数时补空串（渲染层按左对齐处理）
func _start_table(p_aligns: Array[String]) -> void:
	var header_cells: Array = _table_pending_header
	_table_pending_header = []
	_table_pending_line = ""
	if header_cells.is_empty():
		return
	
	_table_columns = header_cells.size()
	_table_aligns = p_aligns
	if _table_aligns.size() != _table_columns:
		_table_aligns.resize(_table_columns)
	_state = _ParseState.TABLE
	
	table_start.emit(_table_columns, _table_aligns)
	table_row.emit(header_cells)


# 闭合表格（未开启时无副作用）
func _close_table() -> void:
	if _state != _ParseState.TABLE:
		return
	_state = _ParseState.TEXT
	_table_columns = 0
	_table_aligns.clear()
	table_end.emit()


# 结束引用块并交付（未开启时无副作用）
func _flush_quote() -> void:
	if _state != _ParseState.QUOTE:
		return
	_state = _ParseState.TEXT
	var lines: PackedStringArray = _quote_lines
	_quote_lines = PackedStringArray()
	quote.emit(lines)


# 流结束时首行仍在缓冲（只有一行的表格）：交付后再闭合
func _finish_pending_table_header() -> void:
	if _table_pending_header.is_empty():
		return
	var aligns: Array[String] = []
	_start_table(aligns)
	_close_table()


# 清空表格相关状态
func _reset_table() -> void:
	_table_pending_header = []
	_table_pending_line = ""
	_table_columns = 0
	_table_aligns.clear()
