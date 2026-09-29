@tool
class_name AIChatHtmlSelector
extends RefCounted

## 轻量 CSS 选择器引擎
##
## 派生自 Godot DOM Parser 的 CSSSelector（MIT License，版权与许可声明见
## res://addons/godot_ai_chat/THIRD_PARTY_LICENSES.md）。
##
## 支持：
##   tag / * / #id / .class / [attr] / [attr=val] / [attr~=val] /
##   [attr^=val] / [attr$=val] / [attr*=val] / [attr|=val]
##   组合器：空格（后代）、>（子）、+（相邻兄弟）、~（后续兄弟）
##   逗号分隔的选择器列表
##   伪类：:first-child / :last-child / :only-child / :first-of-type /
##         :last-of-type / :not(...) / :nth-child / :nth-last-child /
##         :nth-of-type / :nth-last-of-type


# --- Enums / Constants ---

enum Combinator { NONE, DESCENDANT, CHILD, ADJACENT, SIBLING }


# --- Public Functions ---

## 查询全部匹配元素
static func query_all(p_root: AIChatHtmlNode, p_selector: String) -> Array[AIChatHtmlNode]:
	var compiled: Array = _compile(p_selector)
	var result: Array[AIChatHtmlNode] = []
	if compiled.is_empty():
		return result
	for node in p_root.walk_elements():
		if node == p_root:
			continue
		if _matches_any(node, compiled):
			result.append(node)
	return result


## 查询首个匹配元素（文档序）
static func query_first(p_root: AIChatHtmlNode, p_selector: String) -> AIChatHtmlNode:
	var compiled: Array = _compile(p_selector)
	if compiled.is_empty():
		return null
	for node in p_root.walk_elements():
		if node == p_root:
			continue
		if _matches_any(node, compiled):
			return node
	return null


## 判断节点是否匹配选择器
static func matches(p_node: AIChatHtmlNode, p_selector: String) -> bool:
	if not p_node.is_element():
		return false
	return _matches_any(p_node, _compile(p_selector))


# --- Private Functions: Compilation ---

# 复合选择器结构：
#   { tag: String, id: String, classes: Array, attrs: Array, pseudos: Array }
# 复杂选择器为 Array[Dictionary]，每项 { compound, combinator }，按源码顺序排列，
# 最后一项的 combinator 为 NONE。
# 编译结果为 Array[Array]（选择器列表 → 复杂选择器列表）。
static func _compile(p_selector: String) -> Array:
	var groups: Array = []
	for part in _split_top_level(p_selector, ","):
		var trimmed: String = part.strip_edges()
		if trimmed.is_empty():
			continue
		var complex: Array = _compile_complex(trimmed)
		if not complex.is_empty():
			groups.append(complex)
	return groups


static func _compile_complex(p_source: String) -> Array:
	var out: Array = []
	var cursor: int = 0
	var length: int = p_source.length()
	var pending_combinator: Combinator = Combinator.NONE
	while cursor < length:
		while cursor < length and _is_whitespace(p_source[cursor]):
			cursor += 1
			if pending_combinator == Combinator.NONE:
				pending_combinator = Combinator.DESCENDANT
		if cursor >= length:
			break
		var c: String = p_source[cursor]
		if c == ">" or c == "+" or c == "~":
			pending_combinator = _combinator_for(c)
			cursor += 1
			continue
		# 读取一个不含空白与组合器的复合选择器片段
		var start: int = cursor
		var depth: int = 0
		while cursor < length:
			var ch: String = p_source[cursor]
			if ch == "[" or ch == "(":
				depth += 1
			elif ch == "]" or ch == ")":
				depth -= 1
			elif depth == 0 and (_is_whitespace(ch) or ch == ">" or ch == "+" or ch == "~" or ch == ","):
				break
			cursor += 1
		var token: String = p_source.substr(start, cursor - start)
		if token.is_empty():
			break
		# 组合器作用于"前一节 → 当前节"
		if not out.is_empty():
			out[out.size() - 1]["combinator"] = pending_combinator
		out.append({"compound": _compile_compound(token), "combinator": Combinator.NONE})
		pending_combinator = Combinator.NONE
	return out


static func _combinator_for(p_char: String) -> Combinator:
	match p_char:
		">":
			return Combinator.CHILD
		"+":
			return Combinator.ADJACENT
		"~":
			return Combinator.SIBLING
	return Combinator.DESCENDANT


static func _compile_compound(p_source: String) -> Dictionary:
	var compound: Dictionary = {
		"tag": "",
		"id": "",
		"classes": [] as Array,
		"attrs": [] as Array,
		"pseudos": [] as Array,
	}
	var cursor: int = 0
	var length: int = p_source.length()
	# 开头的标签名或通配符
	if cursor < length and (p_source[cursor] == "*" or _is_identifier_start(p_source[cursor])):
		var start: int = cursor
		if p_source[cursor] == "*":
			cursor += 1
		else:
			while cursor < length and _is_identifier(p_source[cursor]):
				cursor += 1
		compound["tag"] = p_source.substr(start, cursor - start).to_lower()
	while cursor < length:
		var c: String = p_source[cursor]
		if c == "#":
			cursor += 1
			var id_start: int = cursor
			while cursor < length and _is_identifier(p_source[cursor]):
				cursor += 1
			compound["id"] = p_source.substr(id_start, cursor - id_start)
		elif c == ".":
			cursor += 1
			var class_start: int = cursor
			while cursor < length and _is_identifier(p_source[cursor]):
				cursor += 1
			compound["classes"].append(p_source.substr(class_start, cursor - class_start))
		elif c == "[":
			var close_index: int = _find_matching(p_source, cursor, "[", "]")
			if close_index == -1:
				cursor = length
				break
			compound["attrs"].append(_compile_attribute(p_source.substr(cursor + 1, close_index - cursor - 1)))
			cursor = close_index + 1
		elif c == ":":
			cursor += 1
			var name_start: int = cursor
			while cursor < length and _is_identifier(p_source[cursor]):
				cursor += 1
			var pseudo_name: String = p_source.substr(name_start, cursor - name_start).to_lower()
			var pseudo_arg: String = ""
			if cursor < length and p_source[cursor] == "(":
				var arg_close: int = _find_matching(p_source, cursor, "(", ")")
				if arg_close == -1:
					cursor = length
					break
				pseudo_arg = p_source.substr(cursor + 1, arg_close - cursor - 1)
				cursor = arg_close + 1
			compound["pseudos"].append({"name": pseudo_name, "arg": pseudo_arg})
		else:
			cursor += 1
	return compound


static func _compile_attribute(p_body: String) -> Dictionary:
	var out: Dictionary = {"name": "", "op": "", "value": ""}
	var trimmed: String = p_body.strip_edges()
	for op in ["~=", "^=", "$=", "*=", "|=", "="]:
		var index: int = trimmed.find(op)
		if index == -1:
			continue
		out["name"] = trimmed.substr(0, index).strip_edges().to_lower()
		out["op"] = op
		var raw: String = trimmed.substr(index + op.length()).strip_edges()
		if raw.length() >= 2 and (raw[0] == "\"" or raw[0] == "'") and raw[raw.length() - 1] == raw[0]:
			raw = raw.substr(1, raw.length() - 2)
		out["value"] = raw
		return out
	out["name"] = trimmed.to_lower()
	return out


# --- Private Functions: Matching ---

static func _matches_any(p_node: AIChatHtmlNode, p_groups: Array) -> bool:
	for complex: Array in p_groups:
		if _matches_complex(p_node, complex):
			return true
	return false


static func _matches_complex(p_node: AIChatHtmlNode, p_complex: Array) -> bool:
	if p_complex.is_empty():
		return false
	var last_index: int = p_complex.size() - 1
	if not _matches_compound(p_node, p_complex[last_index]["compound"]):
		return false
	if last_index == 0:
		return true
	return _matches_complex_upwards(p_node, p_complex, last_index - 1, p_complex[last_index - 1]["combinator"])


# 由当前节点向上回溯，逐节验证前置复合选择器与组合器
static func _matches_complex_upwards(p_node: AIChatHtmlNode, p_complex: Array, p_step_index: int, p_combinator: Combinator) -> bool:
	var compound: Dictionary = p_complex[p_step_index]["compound"]
	match p_combinator:
		Combinator.DESCENDANT:
			var ancestor: AIChatHtmlNode = p_node.parent
			while ancestor != null and ancestor.is_element():
				if _matches_compound(ancestor, compound):
					if p_step_index == 0:
						return true
					if _matches_complex_upwards(ancestor, p_complex, p_step_index - 1, p_complex[p_step_index - 1]["combinator"]):
						return true
				ancestor = ancestor.parent
			return false
		Combinator.CHILD:
			var parent: AIChatHtmlNode = p_node.parent
			if parent == null or not parent.is_element():
				return false
			if not _matches_compound(parent, compound):
				return false
			if p_step_index == 0:
				return true
			return _matches_complex_upwards(parent, p_complex, p_step_index - 1, p_complex[p_step_index - 1]["combinator"])
		Combinator.ADJACENT:
			var previous: AIChatHtmlNode = _previous_element_sibling(p_node)
			if previous == null:
				return false
			if not _matches_compound(previous, compound):
				return false
			if p_step_index == 0:
				return true
			return _matches_complex_upwards(previous, p_complex, p_step_index - 1, p_complex[p_step_index - 1]["combinator"])
		Combinator.SIBLING:
			var sibling: AIChatHtmlNode = _previous_element_sibling(p_node)
			while sibling != null:
				if _matches_compound(sibling, compound):
					if p_step_index == 0:
						return true
					if _matches_complex_upwards(sibling, p_complex, p_step_index - 1, p_complex[p_step_index - 1]["combinator"]):
						return true
				sibling = _previous_element_sibling(sibling)
			return false
	return false


static func _matches_compound(p_node: AIChatHtmlNode, p_compound: Dictionary) -> bool:
	if not p_node.is_element():
		return false
	var tag: String = p_compound["tag"]
	if not tag.is_empty() and tag != "*" and p_node.tag_name != tag:
		return false
	var wanted_id: String = p_compound["id"]
	if not wanted_id.is_empty() and p_node.get_id() != wanted_id:
		return false
	for css_class: String in p_compound["classes"]:
		if not p_node.has_class(css_class):
			return false
	for attribute: Dictionary in p_compound["attrs"]:
		if not _matches_attribute(p_node, attribute):
			return false
	for pseudo: Dictionary in p_compound["pseudos"]:
		if not _matches_pseudo(p_node, pseudo):
			return false
	return true


static func _matches_attribute(p_node: AIChatHtmlNode, p_attribute: Dictionary) -> bool:
	var name: String = p_attribute["name"]
	if not p_node.has_attribute(name):
		return false
	var op: String = p_attribute["op"]
	if op.is_empty():
		return true
	var actual: String = p_node.get_attribute(name)
	var value: String = p_attribute["value"]
	match op:
		"=":
			return actual == value
		"~=":
			for piece in actual.split(" ", false):
				if piece == value:
					return true
			return false
		"^=":
			return not value.is_empty() and actual.begins_with(value)
		"$=":
			return not value.is_empty() and actual.ends_with(value)
		"*=":
			return not value.is_empty() and actual.find(value) != -1
		"|=":
			return actual == value or actual.begins_with(value + "-")
	return false


static func _matches_pseudo(p_node: AIChatHtmlNode, p_pseudo: Dictionary) -> bool:
	match p_pseudo["name"]:
		"first-child":
			return _previous_element_sibling(p_node) == null
		"last-child":
			return _next_element_sibling(p_node) == null
		"only-child":
			return _previous_element_sibling(p_node) == null and _next_element_sibling(p_node) == null
		"first-of-type":
			var parent: AIChatHtmlNode = p_node.parent
			if parent == null:
				return true
			for child in parent.children:
				if child.is_element() and child.tag_name == p_node.tag_name:
					return child == p_node
			return false
		"last-of-type":
			var parent_last: AIChatHtmlNode = p_node.parent
			if parent_last == null:
				return true
			var last: AIChatHtmlNode = null
			for child in parent_last.children:
				if child.is_element() and child.tag_name == p_node.tag_name:
					last = child
			return last == p_node
		"not":
			return not _matches_compound(p_node, _compile_compound(p_pseudo["arg"]))
		"nth-child":
			return _matches_nth_expression(p_pseudo["arg"], _element_index(p_node, false, false))
		"nth-last-child":
			return _matches_nth_expression(p_pseudo["arg"], _element_index(p_node, false, true))
		"nth-of-type":
			return _matches_nth_expression(p_pseudo["arg"], _element_index(p_node, true, false))
		"nth-last-of-type":
			return _matches_nth_expression(p_pseudo["arg"], _element_index(p_node, true, true))
	return false


# --- Private Functions: :nth-* helpers ---

# 返回节点在兄弟元素中的 1-based 序号。
# p_of_type 为 true 时仅统计同名标签；p_from_end 为 true 时从末尾反向计数。
static func _element_index(p_node: AIChatHtmlNode, p_of_type: bool, p_from_end: bool) -> int:
	var parent: AIChatHtmlNode = p_node.parent
	if parent == null:
		return 1
	var siblings: Array[AIChatHtmlNode] = []
	for child in parent.children:
		if not child.is_element():
			continue
		if p_of_type and child.tag_name != p_node.tag_name:
			continue
		siblings.append(child)
	if p_from_end:
		for i in siblings.size():
			if siblings[siblings.size() - 1 - i] == p_node:
				return i + 1
	else:
		for i in siblings.size():
			if siblings[i] == p_node:
				return i + 1
	return 0


# 解析并测试 an+b 微表达式
static func _matches_nth_expression(p_arg: String, p_index_one_based: int) -> bool:
	if p_index_one_based <= 0:
		return false
	var parsed: Array = _parse_an_plus_b(p_arg)
	if parsed.is_empty():
		return false
	var coefficient: int = parsed[0]
	var offset: int = parsed[1]
	if coefficient == 0:
		return p_index_one_based == offset
	var difference: int = p_index_one_based - offset
	if difference % coefficient != 0:
		return false
	@warning_ignore("integer_division")
	var step: int = difference / coefficient
	return step >= 0


# 解析 CSS an+b 记法为 [a, b]；支持 odd / even / 纯整数 / n / -n / 2n+1 等。
# 解析失败返回空数组。
static func _parse_an_plus_b(p_arg: String) -> Array:
	var text: String = p_arg.strip_edges().to_lower()
	if text.is_empty():
		return []
	if text == "odd":
		return [2, 1]
	if text == "even":
		return [2, 0]
	text = text.replace(" ", "")
	var n_index: int = text.find("n")
	if n_index == -1:
		if _is_signed_integer(text):
			return [0, text.to_int()]
		return []
	var coefficient_text: String = text.substr(0, n_index)
	var offset_text: String = text.substr(n_index + 1)
	var coefficient: int = 0
	if coefficient_text.is_empty() or coefficient_text == "+":
		coefficient = 1
	elif coefficient_text == "-":
		coefficient = -1
	elif _is_signed_integer(coefficient_text):
		coefficient = coefficient_text.to_int()
	else:
		return []
	var offset: int = 0
	if not offset_text.is_empty():
		if not _is_signed_integer(offset_text):
			return []
		offset = offset_text.to_int()
	return [coefficient, offset]


static func _is_signed_integer(p_text: String) -> bool:
	if p_text.is_empty() or p_text == "+" or p_text == "-":
		return false
	if p_text[0] == "+" or p_text[0] == "-":
		return p_text.substr(1).is_valid_int()
	return p_text.is_valid_int()


# --- Private Functions: Sibling helpers ---

static func _previous_element_sibling(p_node: AIChatHtmlNode) -> AIChatHtmlNode:
	var parent: AIChatHtmlNode = p_node.parent
	if parent == null:
		return null
	var index: int = parent.children.find(p_node)
	for i in range(index - 1, -1, -1):
		if parent.children[i].is_element():
			return parent.children[i]
	return null


static func _next_element_sibling(p_node: AIChatHtmlNode) -> AIChatHtmlNode:
	var parent: AIChatHtmlNode = p_node.parent
	if parent == null:
		return null
	var index: int = parent.children.find(p_node)
	for i in range(index + 1, parent.children.size()):
		if parent.children[i].is_element():
			return parent.children[i]
	return null


# --- Private Functions: Lexical helpers ---

static func _is_whitespace(p_char: String) -> bool:
	return p_char == " " or p_char == "\t" or p_char == "\n" or p_char == "\r" or p_char == "\f"


static func _is_identifier_start(p_char: String) -> bool:
	if p_char.length() == 0:
		return false
	var code: int = p_char.unicode_at(0)
	return (code >= 0x41 and code <= 0x5A) or (code >= 0x61 and code <= 0x7A) or p_char == "_" or p_char == "-"


static func _is_identifier(p_char: String) -> bool:
	if p_char.length() == 0:
		return false
	if _is_identifier_start(p_char):
		return true
	var code: int = p_char.unicode_at(0)
	return code >= 0x30 and code <= 0x39


# 按顶层分隔符切分（忽略 [] 与 () 内部的分隔符）
static func _split_top_level(p_source: String, p_separator: String) -> Array:
	var out: Array = []
	var depth: int = 0
	var start: int = 0
	var cursor: int = 0
	var length: int = p_source.length()
	while cursor < length:
		var c: String = p_source[cursor]
		if c == "[" or c == "(":
			depth += 1
		elif c == "]" or c == ")":
			depth -= 1
		elif depth == 0 and c == p_separator:
			out.append(p_source.substr(start, cursor - start))
			start = cursor + 1
		cursor += 1
	out.append(p_source.substr(start, length - start))
	return out


# 查找与起始括号配对的闭合括号位置，失败返回 -1
static func _find_matching(p_source: String, p_start: int, p_open: String, p_close: String) -> int:
	var depth: int = 0
	var cursor: int = p_start
	var length: int = p_source.length()
	while cursor < length:
		var c: String = p_source[cursor]
		if c == p_open:
			depth += 1
		elif c == p_close:
			depth -= 1
			if depth == 0:
				return cursor
		cursor += 1
	return -1
