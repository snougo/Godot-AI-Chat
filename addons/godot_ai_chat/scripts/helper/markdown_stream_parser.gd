@tool
class_name MarkdownStreamParser
extends RefCounted

## 流式 Markdown 解析器
##
## 将流式输入的文本解析为结构化段落，采用逐行状态机方式。
## 遵循 CommonMark 规范的围栏代码块规则，确保代码块检测的准确性。
## 支持反引号围栏（```）和波浪线围栏（~~~）。
##
## 使用方式：
##   1. 连接 segment_parsed 信号
##   2. 调用 feed() 喂入流式文本
##   3. 流结束时调用 flush() 刷新残余缓冲区
##   4. 重置时调用 reset()

# --- Signals ---

## 当解析出一个段落时触发
## [param p_type]: 段落类型 (SegmentType 枚举值)
## [param p_content]: 段落内容（TEXT 和 CODE_BLOCK_CONTENT 含尾随换行符）
## [param p_meta]: 附加信息（仅 CODE_BLOCK_START 时为语言标识符，其余为空字符串）
signal segment_parsed(p_type: int, p_content: String, p_meta: String)

# --- Enums ---

## 段落类型
enum SegmentType {
	TEXT,               ## 普通文本（p_content 含换行符）
	CODE_BLOCK_START,   ## 代码块开始（p_meta 为语言标识符，如 "python"）
	CODE_BLOCK_CONTENT, ## 代码块内容（p_content 含换行符）
	CODE_BLOCK_END,     ## 代码块结束（p_content 和 p_meta 均为空）
}

## 内部解析状态（不暴露给外部）
enum _ParseState {
	TEXT,   ## 普通文本模式
	CODE,   ## 围栏代码块模式
}

# --- Private Vars ---

## 当前解析状态
var _state: int = _ParseState.TEXT

## 不完整行的缓冲区（仅包含尚未以 \n 结尾的内容）
var _line_buffer: String = ""

## 当前代码块使用的围栏字符串（如 "```" 或 "~~~~"）
var _current_fence: String = ""

## 当前围栏的长度（用于判定闭合围栏是否足够长）
var _current_fence_len: int = 0

## 当前围栏的字符类型（"`" 或 "~"）
var _fence_char: String = ""

# --- 正则表达式（预编译） ---
# CommonMark 规则：
#   - 开启围栏：0-3 空格缩进 + 3+ 围栏字符 + 可选 info string（不含同种围栏字符）
#   - 闭合围栏：0-3 空格缩进 + 3+ 围栏字符 + 仅水平空白

## 反引号围栏开始行
var _re_open_backtick: RegEx = RegEx.create_from_string("^( {0,3})(`{3,})([^`]*)$")
## 反引号围栏结束行
var _re_close_backtick: RegEx = RegEx.create_from_string("^( {0,3})(`{3,})[ \\t]*$")
## 波浪线围栏开始行
var _re_open_tilde: RegEx = RegEx.create_from_string("^( {0,3})(~{3,})([^~]*)$")
## 波浪线围栏结束行
var _re_close_tilde: RegEx = RegEx.create_from_string("^( {0,3})(~{3,})[ \\t]*$")


# --- Public Functions ---

## 重置解析器到初始状态
func reset() -> void:
	_state = _ParseState.TEXT
	_line_buffer = ""
	_current_fence = ""
	_current_fence_len = 0
	_fence_char = ""


## 喂入一段文本，自动提取完整行并解析
## [param p_text]: 新增的文本片段
func feed(p_text: String) -> void:
	if p_text.is_empty():
		return
	_line_buffer += p_text
	_drain_lines()


## 刷新缓冲区（流结束时必须调用）
## 将缓冲区中不完整的最后一行作为独立行处理
func flush() -> void:
	if _line_buffer.is_empty():
		return

	var remaining: String = _line_buffer
	_line_buffer = ""

	# \r 兼容处理
	if remaining.ends_with("\r"):
		remaining = remaining.left(-1)

	if not remaining.is_empty():
		_process_line(remaining)


## 查询当前是否在代码块内
func is_in_code_block() -> bool:
	return _state == _ParseState.CODE


## 获取缓冲区中尚未处理的文本（可用于 UI 预览）
func get_pending_text() -> String:
	return _line_buffer


# --- Private Functions ---

## 从缓冲区中提取并处理所有完整行
## 完整行 = 以 \n 结尾的行
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


## 处理单行文本（状态机入口）
func _process_line(p_line: String) -> void:
	match _state:
		_ParseState.TEXT:
			_process_text_line(p_line)
		_ParseState.CODE:
			_process_code_line(p_line)


## 处理 TEXT 模式下的行
## 检测是否为围栏代码块开始行，否则作为普通文本输出
func _process_text_line(p_line: String) -> void:
	# 1. 尝试匹配反引号围栏开始
	var m: RegExMatch = _re_open_backtick.search(p_line)
	if m:
		var fence: String = m.get_string(2)
		var info: String = m.get_string(3).strip_edges()
		# CommonMark：反引号围栏的 info string 不能包含反引号
		if not info.contains("`"):
			_enter_code_block(fence, info, "`")
			return

	# 2. 尝试匹配波浪线围栏开始
	m = _re_open_tilde.search(p_line)
	if m:
		var fence: String = m.get_string(2)
		var info: String = m.get_string(3).strip_edges()
		# CommonMark：波浪线围栏的 info string 不能包含波浪线
		if not info.contains("~"):
			_enter_code_block(fence, info, "~")
			return

	# 3. 非围栏行 → 普通文本
	segment_parsed.emit(SegmentType.TEXT, p_line + "\n", "")


## 处理 CODE 模式下的行
## 检测是否为闭合围栏行，否则作为代码内容输出
func _process_code_line(p_line: String) -> void:
	# 仅检测与当前围栏类型匹配的闭合围栏
	var m: RegExMatch
	if _fence_char == "`":
		m = _re_close_backtick.search(p_line)
	else:
		m = _re_close_tilde.search(p_line)

	if m:
		var fence: String = m.get_string(2)
		# CommonMark：闭合围栏长度必须 >= 开启围栏长度
		if fence.length() >= _current_fence_len:
			_exit_code_block()
			return

	# 非闭合行 → 代码内容
	segment_parsed.emit(SegmentType.CODE_BLOCK_CONTENT, p_line + "\n", "")


## 进入代码块状态
func _enter_code_block(p_fence: String, p_lang: String, p_char: String) -> void:
	_state = _ParseState.CODE
	_current_fence = p_fence
	_current_fence_len = p_fence.length()
	_fence_char = p_char
	segment_parsed.emit(SegmentType.CODE_BLOCK_START, "", p_lang)


## 退出代码块状态
func _exit_code_block() -> void:
	_state = _ParseState.TEXT
	_current_fence = ""
	_current_fence_len = 0
	_fence_char = ""
	segment_parsed.emit(SegmentType.CODE_BLOCK_END, "", "")
