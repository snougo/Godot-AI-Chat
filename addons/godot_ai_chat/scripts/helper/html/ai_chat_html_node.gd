@tool
class_name AIChatHtmlNode
extends RefCounted

## HTML DOM 节点
##
## 派生自 Godot DOM Parser 的 DOMNode（MIT License，版权与许可声明见
## res://addons/godot_ai_chat/THIRD_PARTY_LICENSES.md），针对网页抓取场景做了调整：
## - 文本 / HTML 序列化改用 Array[String] 拼接，消除平方级字符串拷贝；
## - has_class() 不再分配临时数组；
## - 新增 append_walk_into()，允许复用遍历结果数组，避免反复整树遍历。


# --- Enums / Constants ---

## 节点类型
enum NodeType {
	ELEMENT,   ## 元素
	TEXT,      ## 文本
	COMMENT,   ## 注释
	DOCUMENT,  ## 文档根
}

## HTML 空元素（无结束标签、无子节点）
const VOID_ELEMENTS: Array[String] = [
	"area", "base", "br", "col", "embed", "hr", "img", "input",
	"link", "meta", "param", "source", "track", "wbr",
]


# --- Public Vars ---

var node_type: NodeType = NodeType.ELEMENT
var tag_name: String = ""
var attributes: Dictionary = {}
var children: Array[AIChatHtmlNode] = []
var text: String = ""
var parent: AIChatHtmlNode = null


# --- Public Functions ---

## 创建元素节点（标签名统一小写）
static func create_element(p_tag: String) -> AIChatHtmlNode:
	var node := AIChatHtmlNode.new()
	node.node_type = NodeType.ELEMENT
	node.tag_name = p_tag.to_lower()
	return node


## 创建文本节点
static func create_text(p_text: String) -> AIChatHtmlNode:
	var node := AIChatHtmlNode.new()
	node.node_type = NodeType.TEXT
	node.text = p_text
	return node


## 创建注释节点
static func create_comment(p_text: String) -> AIChatHtmlNode:
	var node := AIChatHtmlNode.new()
	node.node_type = NodeType.COMMENT
	node.text = p_text
	return node


## 是否为元素节点
func is_element() -> bool:
	return node_type == NodeType.ELEMENT


## 是否为文本节点
func is_text() -> bool:
	return node_type == NodeType.TEXT


## 是否为空元素（br / img 等）
func is_void() -> bool:
	return is_element() and VOID_ELEMENTS.has(tag_name)


## 追加子节点（会自动从原父节点摘除）
func append_child(p_child: AIChatHtmlNode) -> AIChatHtmlNode:
	if p_child.parent != null:
		p_child.parent.remove_child(p_child)
	p_child.parent = self
	children.append(p_child)
	return p_child


## 移除指定子节点
func remove_child(p_child: AIChatHtmlNode) -> AIChatHtmlNode:
	var index: int = children.find(p_child)
	if index != -1:
		children.remove_at(index)
		p_child.parent = null
	return p_child


## 将自身从父节点摘除
func remove() -> void:
	if parent != null:
		parent.remove_child(self)


## 是否存在指定属性（属性名不区分大小写）
func has_attribute(p_name: String) -> bool:
	return attributes.has(p_name.to_lower())


## 读取属性值（不存在时返回 p_default）
func get_attribute(p_name: String, p_default: String = "") -> String:
	var key: String = p_name.to_lower()
	if attributes.has(key):
		return str(attributes[key])
	return p_default


## 设置属性
func set_attribute(p_name: String, p_value: String) -> void:
	attributes[p_name.to_lower()] = p_value


## 移除属性
func remove_attribute(p_name: String) -> void:
	attributes.erase(p_name.to_lower())


## 读取 id 属性
func get_id() -> String:
	return get_attribute("id")


## 读取 class 列表
func get_classes() -> PackedStringArray:
	var raw: String = get_attribute("class")
	if raw.is_empty():
		return PackedStringArray()
	var result := PackedStringArray()
	for piece in raw.split(" ", false):
		var trimmed: String = piece.strip_edges()
		if not trimmed.is_empty():
			result.append(trimmed)
	return result


## 是否含有指定 class（按空白边界精确匹配，不分配临时数组）
func has_class(p_class: String) -> bool:
	if p_class.is_empty():
		return false
	var raw: String = get_attribute("class")
	if raw.is_empty():
		return false
	var name_length: int = p_class.length()
	var index: int = raw.find(p_class)
	while index != -1:
		var end_index: int = index + name_length
		var left_ok: bool = index == 0 or _is_space_char(raw[index - 1])
		var right_ok: bool = end_index >= raw.length() or _is_space_char(raw[end_index])
		if left_ok and right_ok:
			return true
		index = raw.find(p_class, index + 1)
	return false


## 收集自身及全部后代的纯文本
func get_text_content() -> String:
	if is_text():
		return text
	if node_type == NodeType.COMMENT:
		return ""
	var parts: Array[String] = []
	_collect_text(parts)
	return "".join(parts)


## 自身的内部 HTML
func get_inner_html() -> String:
	var parts: Array[String] = []
	for child in children:
		child._collect_outer_html(parts)
	return "".join(parts)


## 自身的外部 HTML
func get_outer_html() -> String:
	var parts: Array[String] = []
	_collect_outer_html(parts)
	return "".join(parts)


## 深度优先遍历（含自身），返回全部节点
func walk() -> Array[AIChatHtmlNode]:
	var result: Array[AIChatHtmlNode] = []
	append_walk_into(result)
	return result


## 深度优先遍历（含自身），将节点追加到 p_out
## 复用同一个结果数组可避免每次查询都重新分配整棵树的节点列表
func append_walk_into(p_out: Array[AIChatHtmlNode]) -> void:
	p_out.append(self)
	for child in children:
		child.append_walk_into(p_out)


## 深度优先遍历，仅返回元素节点
func walk_elements() -> Array[AIChatHtmlNode]:
	var result: Array[AIChatHtmlNode] = []
	_append_elements_into(result)
	return result


## 按 id 查找元素
func get_element_by_id(p_id: String) -> AIChatHtmlNode:
	for node in walk_elements():
		if node.get_id() == p_id:
			return node
	return null


## 按标签名查找元素（"*" 表示全部）
func get_elements_by_tag_name(p_tag: String) -> Array[AIChatHtmlNode]:
	var lower: String = p_tag.to_lower()
	var result: Array[AIChatHtmlNode] = []
	for node in walk_elements():
		if lower == "*" or node.tag_name == lower:
			result.append(node)
	return result


## 按 class 名查找元素
func get_elements_by_class_name(p_class: String) -> Array[AIChatHtmlNode]:
	var result: Array[AIChatHtmlNode] = []
	for node in walk_elements():
		if node.has_class(p_class):
			result.append(node)
	return result


## CSS 选择器查询，返回首个匹配元素
func query_selector(p_selector: String) -> AIChatHtmlNode:
	return AIChatHtmlSelector.query_first(self, p_selector)


## CSS 选择器查询，返回全部匹配元素
func query_selector_all(p_selector: String) -> Array[AIChatHtmlNode]:
	return AIChatHtmlSelector.query_all(self, p_selector)


## 自身是否匹配指定 CSS 选择器
func matches(p_selector: String) -> bool:
	return AIChatHtmlSelector.matches(self, p_selector)


# --- Private Functions ---

# 递归收集纯文本
func _collect_text(p_out: Array[String]) -> void:
	for child in children:
		if child.is_text():
			p_out.append(child.text)
		elif child.is_element():
			child._collect_text(p_out)


# 递归收集元素节点
func _append_elements_into(p_out: Array[AIChatHtmlNode]) -> void:
	for child in children:
		if child.is_element():
			p_out.append(child)
		child._append_elements_into(p_out)


# 递归收集外部 HTML
func _collect_outer_html(p_out: Array[String]) -> void:
	match node_type:
		NodeType.TEXT:
			p_out.append(_escape_text(text))
		NodeType.COMMENT:
			p_out.append("<!--%s-->" % text)
		NodeType.DOCUMENT:
			for child in children:
				child._collect_outer_html(p_out)
		_:
			var attr_parts: Array[String] = []
			for key: Variant in attributes:
				attr_parts.append(" %s=\"%s\"" % [str(key), _escape_attribute(str(attributes[key]))])
			p_out.append("<%s%s>" % [tag_name, "".join(attr_parts)])
			if is_void():
				return
			for child in children:
				child._collect_outer_html(p_out)
			p_out.append("</%s>" % tag_name)


# 是否 HTML 空白字符
static func _is_space_char(p_char: String) -> bool:
	return p_char == " " or p_char == "\t" or p_char == "\n" or p_char == "\r" or p_char == "\f"


# 转义文本节点内容
static func _escape_text(p_text: String) -> String:
	return p_text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


# 转义属性值
static func _escape_attribute(p_text: String) -> String:
	return p_text.replace("&", "&amp;").replace("\"", "&quot;")
