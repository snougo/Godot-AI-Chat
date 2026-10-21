@tool
class_name AIChatHtmlParser
extends RefCounted

## 宽容式 HTML 解析器
##
## 派生自 Godot DOM Parser 的 HTMLParser（MIT License，版权与许可声明见
## res://addons/godot_ai_chat/THIRD_PARTY_LICENSES.md）。
##
## 针对抓取场景的改动：
## - parse() 支持 p_drop_tags：解析期直接丢弃噪音标签子树（script/style 连内容一起跳过），
##   把原先"对每个噪音标签各做一次全树遍历"的 9 次遍历压缩为 0 次；
## - 文本扫描改用 find() 定位，实体解码改用片段拼接，消除逐字符循环与平方级字符串拷贝；
## - 命名实体表扩充；支持 <?xml ?> 处理指令与 <![CDATA[]]> 跳过。


# --- Enums / Constants ---

## 内容为原始文本的元素（内部不解析嵌套标签）
const RAW_TEXT_ELEMENTS: Array[String] = ["script", "style"]

## 内容为 RCDATA 的元素（解析实体，但不解析标签）
const RCDATA_ELEMENTS: Array[String] = ["textarea", "title"]

## 同名标签再次出现时需要隐式闭合的同级元素
const IMPLICIT_CLOSE_PEERS: Dictionary = {
	"li": ["li"],
	"p": ["p"],
	"dt": ["dt", "dd"],
	"dd": ["dt", "dd"],
	"tr": ["tr"],
	"td": ["td", "th"],
	"th": ["td", "th"],
	"thead": ["thead", "tbody", "tfoot"],
	"tbody": ["thead", "tbody", "tfoot"],
	"tfoot": ["thead", "tbody", "tfoot"],
	"option": ["option"],
}

## 出现这些块级标签时会隐式闭合未闭合的 <p>
const P_CLOSERS: Array[String] = [
	"address", "article", "aside", "blockquote", "details", "div", "dl",
	"fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
	"h4", "h5", "h6", "header", "hr", "main", "menu", "nav", "ol", "p",
	"pre", "section", "table", "ul",
]

## 命名实体表（覆盖常见排版、数学、货币与符号字符）
const NAMED_ENTITIES: Dictionary = {
	"amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
	"nbsp": " ", "ensp": " ", "emsp": " ", "thinsp": " ", "shy": "",
	"copy": "©", "reg": "®", "trade": "™", "deg": "°", "micro": "µ",
	"para": "¶", "sect": "§", "bull": "•", "hellip": "…", "prime": "′",
	"mdash": "—", "ndash": "–", "minus": "−", "horbar": "―",
	"lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
	"sbquo": "‚", "bdquo": "„", "laquo": "«", "raquo": "»",
	"dagger": "†", "Dagger": "‡", "middot": "·", "permil": "‰",
	"times": "×", "divide": "÷", "plusmn": "±", "ne": "≠",
	"le": "≤", "ge": "≥", "asymp": "≈", "equiv": "≡",
	"infin": "∞", "sum": "∑", "prod": "∏", "radic": "√",
	"int": "∫", "part": "∂", "nabla": "∇", "prop": "∝",
	"frac12": "½", "frac14": "¼", "frac34": "¾", "sup2": "²", "sup3": "³",
	"larr": "←", "uarr": "↑", "rarr": "→", "darr": "↓", "harr": "↔",
	"euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "curren": "¤",
	"alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ",
	"epsilon": "ε", "theta": "θ", "lambda": "λ", "mu": "μ",
	"pi": "π", "sigma": "σ", "phi": "φ", "omega": "ω",
	"Omega": "Ω", "Delta": "Δ", "Sigma": "Σ", "Pi": "Π",
	"check": "✓", "cross": "✗", "star": "★", "hearts": "♥",
	"loz": "◊", "spades": "♠", "clubs": "♣", "diams": "♦",
}


# --- Private Vars ---

var _source: String = ""
var _cursor: int = 0
var _length: int = 0
var _drop_set: Dictionary = {}


# --- Public Functions ---

## 解析 HTML 字符串为文档树
## [param p_html]: 原始 HTML 文本
## [param p_drop_tags]: 需要丢弃的标签名列表；命中标签的整棵子树都不会进入 DOM
static func parse(p_html: String, p_drop_tags: PackedStringArray = PackedStringArray()) -> AIChatHtmlDocument:
	var parser := AIChatHtmlParser.new()
	parser._drop_set = _build_drop_set(p_drop_tags)
	return parser._parse(p_html)


# --- Built-in Functions ---

func _parse(p_html: String) -> AIChatHtmlDocument:
	_source = p_html
	_cursor = 0
	_length = p_html.length()
	
	var document := AIChatHtmlDocument.new()
	document.raw_html = p_html
	var stack: Array[AIChatHtmlNode] = [document]
	
	while _cursor < _length:
		var character: String = _source[_cursor]
		if character != "<":
			_consume_text(stack.back())
		elif _match_ci_at(_cursor, "<!--"):
			_consume_comment(stack.back())
		elif _match_ci_at(_cursor, "<![cdata["):
			_consume_cdata(stack.back())
		elif _match_ci_at(_cursor, "<!"):
			_skip_until(">")
			if _cursor < _length:
				_cursor += 1
		elif _match_ci_at(_cursor, "<?"):
			_skip_until("?>")
			_cursor = mini(_cursor + 2, _length)
		elif _cursor + 1 < _length and _source[_cursor + 1] == "/":
			_consume_end_tag(stack)
		elif _cursor + 1 < _length and _is_tag_name_start(_source[_cursor + 1]):
			_consume_start_tag(stack)
		else:
			# 游离的 "<" —— 视为普通文本
			_append_text(stack.back(), "<")
			_cursor += 1
	
	return document


# --- Private Functions: Tokenizing helpers ---

# 构建丢弃标签集合
static func _build_drop_set(p_drop_tags: PackedStringArray) -> Dictionary:
	var drop_set: Dictionary = {}
	for tag in p_drop_tags:
		var lower: String = tag.strip_edges().to_lower()
		if not lower.is_empty():
			drop_set[lower] = true
	
	return drop_set


# 从 p_position 起是否匹配 p_prefix（大小写不敏感，p_prefix 必须为小写）
func _match_ci_at(p_position: int, p_prefix: String) -> bool:
	var prefix_length: int = p_prefix.length()
	if p_position + prefix_length > _length:
		return false
	
	for offset in prefix_length:
		var code: int = _source.unicode_at(p_position + offset)
		if code >= 0x41 and code <= 0x5A:
			code += 0x20
		if code != p_prefix.unicode_at(offset):
			return false
	
	return true


# 从当前位置向后查找 p_lower_needle（大小写不敏感）首次出现的位置
func _find_ci(p_from: int, p_lower_needle: String) -> int:
	var search: int = p_from
	while true:
		var found: int = _source.find("<", search)
		if found == -1:
			return -1
		if _match_ci_at(found, p_lower_needle):
			return found
		search = found + 1
	
	return -1


func _is_tag_name_start(p_char: String) -> bool:
	if p_char.length() == 0:
		return false
	
	var code: int = p_char.unicode_at(0)
	return (code >= 0x41 and code <= 0x5A) or (code >= 0x61 and code <= 0x7A)


func _is_tag_name_code(p_code: int) -> bool:
	if (p_code >= 0x41 and p_code <= 0x5A) or (p_code >= 0x61 and p_code <= 0x7A):
		return true
	if p_code >= 0x30 and p_code <= 0x39:
		return true
	
	return p_code == 0x2D or p_code == 0x5F or p_code == 0x3A


func _is_space_code(p_code: int) -> bool:
	return p_code == 0x20 or p_code == 0x09 or p_code == 0x0A or p_code == 0x0D or p_code == 0x0C


func _skip_whitespace() -> void:
	while _cursor < _length and _is_space_code(_source.unicode_at(_cursor)):
		_cursor += 1


func _skip_until(p_target: String) -> void:
	var found: int = _source.find(p_target, _cursor)
	_cursor = _length if found == -1 else found


# --- Private Functions: Token consumers ---

func _consume_comment(p_parent: AIChatHtmlNode) -> void:
	_cursor += 4  # 跳过 "<!--"
	
	var end_index: int = _source.find("-->", _cursor)
	if end_index == -1:
		p_parent.append_child(AIChatHtmlNode.create_comment(_source.substr(_cursor)))
		_cursor = _length
		return
	
	p_parent.append_child(AIChatHtmlNode.create_comment(_source.substr(_cursor, end_index - _cursor)))
	_cursor = end_index + 3


func _consume_cdata(p_parent: AIChatHtmlNode) -> void:
	_cursor += 9  # 跳过 "<![CDATA["
	
	var end_index: int = _source.find("]]>", _cursor)
	if end_index == -1:
		_append_text(p_parent, _source.substr(_cursor))
		_cursor = _length
		return
	
	_append_text(p_parent, _source.substr(_cursor, end_index - _cursor))
	_cursor = end_index + 3


func _consume_text(p_parent: AIChatHtmlNode) -> void:
	var start: int = _cursor
	var next_tag: int = _source.find("<", _cursor)
	
	_cursor = _length if next_tag == -1 else next_tag
	if _cursor > start:
		_append_text(p_parent, _decode_entities(_source.substr(start, _cursor - start)))


func _append_text(p_parent: AIChatHtmlNode, p_text: String) -> void:
	if p_text.is_empty():
		return
	
	# 合并相邻文本节点
	if not p_parent.children.is_empty():
		var last: AIChatHtmlNode = p_parent.children[p_parent.children.size() - 1]
		if last.is_text():
			last.text += p_text
			return
	
	p_parent.append_child(AIChatHtmlNode.create_text(p_text))


func _consume_end_tag(stack: Array[AIChatHtmlNode]) -> void:
	_cursor += 2  # 跳过 "</"
	var name: String = _read_tag_name()
	_skip_until(">")
	
	if _cursor < _length:
		_cursor += 1
	
	if name.is_empty():
		return
	
	name = name.to_lower()
	# 向上回溯到匹配的元素并闭合
	for index in range(stack.size() - 1, 0, -1):
		if stack[index].tag_name == name:
			while stack.size() > index:
				stack.pop_back()
			return


func _consume_start_tag(stack: Array[AIChatHtmlNode]) -> void:
	_cursor += 1  # 跳过 "<"
	
	var name: String = _read_tag_name().to_lower()
	if name.is_empty():
		_append_text(stack.back(), "<")
		return
	
	var attributes: Dictionary = _read_attributes()
	var is_self_closing: bool = false
	_skip_whitespace()
	
	if _cursor < _length and _source[_cursor] == "/":
		is_self_closing = true
		_cursor += 1
	
	_skip_whitespace()
	
	if _cursor < _length and _source[_cursor] == ">":
		_cursor += 1
	
	# 丢弃标签：原始文本元素连内容一起跳过，其余交给解析后的修剪阶段
	if _drop_set.has(name):
		if name in RAW_TEXT_ELEMENTS:
			_skip_raw_text(name)
			return
	
	var node := AIChatHtmlNode.create_element(name)
	node.attributes = attributes
	
	_handle_implicit_close(stack, name)
	stack.back().append_child(node)
	
	if node.is_void() or is_self_closing:
		return
	
	if name in RAW_TEXT_ELEMENTS:
		_consume_raw_text(node, name, false)
		return
	if name in RCDATA_ELEMENTS:
		_consume_raw_text(node, name, true)
		return
	
	stack.append(node)


func _handle_implicit_close(stack: Array[AIChatHtmlNode], p_opening: String) -> void:
	if stack.size() <= 1:
		return
	
	var top: AIChatHtmlNode = stack.back()
	if not top.is_element():
		return
	
	# <p> 遇到块级开标签时自动闭合
	if top.tag_name == "p" and p_opening in P_CLOSERS:
		stack.pop_back()
		return
	
	# 同级元素自动闭合（li/li、tr/tr 等）
	if IMPLICIT_CLOSE_PEERS.has(p_opening):
		var closers: Array = IMPLICIT_CLOSE_PEERS[p_opening]
		if top.tag_name in closers:
			stack.pop_back()


func _consume_raw_text(p_parent: AIChatHtmlNode, p_name: String, p_decode_entities_flag: bool) -> void:
	var start: int = _cursor
	
	var end_index: int = _find_ci(_cursor, "</" + p_name)
	if end_index == -1:
		_cursor = _length
	else:
		_cursor = end_index
	
	if _cursor > start:
		var body: String = _source.substr(start, _cursor - start)
		if p_decode_entities_flag:
			body = _decode_entities(body)
		_append_text(p_parent, body)
	
	_skip_until(">")
	
	if _cursor < _length:
		_cursor += 1


# 跳过原始文本元素的内容（丢弃场景，不建节点）
func _skip_raw_text(p_name: String) -> void:
	var end_index: int = _find_ci(_cursor, "</" + p_name)
	_cursor = _length if end_index == -1 else end_index
	_skip_until(">")
	
	if _cursor < _length:
		_cursor += 1


func _read_tag_name() -> String:
	var start: int = _cursor
	while _cursor < _length and _is_tag_name_code(_source.unicode_at(_cursor)):
		_cursor += 1
	
	return _source.substr(start, _cursor - start)


func _read_attributes() -> Dictionary:
	var out: Dictionary = {}
	
	while _cursor < _length:
		_skip_whitespace()
		if _cursor >= _length:
			break
		
		var character: String = _source[_cursor]
		if character == ">" or character == "/":
			break
		
		# 属性名
		var name_start: int = _cursor
		while _cursor < _length:
			var code: int = _source.unicode_at(_cursor)
			if code == 0x3D or code == 0x3E or code == 0x2F or _is_space_code(code):
				break
			
			_cursor += 1
		
		var attribute_name: String = _source.substr(name_start, _cursor - name_start).to_lower()
		if attribute_name.is_empty():
			_cursor += 1  # 防御异常输入导致的死循环
			continue
		
		_skip_whitespace()
		
		var value: String = ""
		if _cursor < _length and _source[_cursor] == "=":
			_cursor += 1
			_skip_whitespace()
			value = _read_attribute_value()
		out[attribute_name] = value
	
	return out


func _read_attribute_value() -> String:
	if _cursor >= _length:
		return ""
	
	var quote: String = _source[_cursor]
	if quote == "\"" or quote == "'":
		_cursor += 1
		var closed_index: int = _source.find(quote, _cursor)
		if closed_index == -1:
			var raw_tail: String = _source.substr(_cursor)
			_cursor = _length
			return _decode_entities(raw_tail)
		
		var raw_quoted: String = _source.substr(_cursor, closed_index - _cursor)
		_cursor = closed_index + 1
		return _decode_entities(raw_quoted)
	
	# 无引号属性值：终止于空白或 ">"；"/" 只有在紧跟 ">" 时才算自闭合标记
	# （href=http://a/b 这类无引号 URL 中的斜杠必须留在值内，否则整段标签会被当成正文）
	var start: int = _cursor
	while _cursor < _length:
		var code: int = _source.unicode_at(_cursor)
		if _is_space_code(code) or code == 0x3E:
			break
		if code == 0x2F and _cursor + 1 < _length and _source.unicode_at(_cursor + 1) == 0x3E:
			break
		_cursor += 1
	
	return _decode_entities(_source.substr(start, _cursor - start))


# --- Private Functions: Entities ---

# 解码 HTML 实体；未知实体原样保留
static func _decode_entities(p_text: String) -> String:
	var amp_index: int = p_text.find("&")
	if amp_index == -1:
		return p_text
	
	var parts: Array[String] = []
	var last: int = 0
	
	while amp_index != -1:
		parts.append(p_text.substr(last, amp_index - last))
		var semicolon: int = p_text.find(";", amp_index + 1)
		
		if semicolon == -1 or semicolon - amp_index > 12:
			parts.append("&")
			last = amp_index + 1
		else:
			var body: String = p_text.substr(amp_index + 1, semicolon - amp_index - 1)
			var decoded: String = _decode_entity_body(body)
			if decoded.is_empty():
				parts.append(p_text.substr(amp_index, semicolon - amp_index + 1))
			else:
				parts.append(decoded)
			last = semicolon + 1
		
		amp_index = p_text.find("&", last)
	
	parts.append(p_text.substr(last))
	return "".join(parts)


static func _decode_entity_body(p_body: String) -> String:
	if p_body.is_empty():
		return ""
	
	if p_body[0] == "#":
		var number_text: String = p_body.substr(1)
		var code: int = 0
		if number_text.begins_with("x") or number_text.begins_with("X"):
			code = ("0x" + number_text.substr(1)).hex_to_int()
		elif number_text.is_valid_int():
			code = number_text.to_int()
		else:
			return ""
		if code <= 0:
			return ""
		
		return String.chr(code)
	
	if NAMED_ENTITIES.has(p_body):
		return NAMED_ENTITIES[p_body]
	
	return ""
