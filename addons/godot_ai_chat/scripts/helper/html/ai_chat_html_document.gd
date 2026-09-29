@tool
class_name AIChatHtmlDocument
extends AIChatHtmlNode

## HTML 文档根节点
##
## 派生自 Godot DOM Parser 的 DOMDocument（MIT License，版权与许可声明见
## res://addons/godot_ai_chat/THIRD_PARTY_LICENSES.md）。
## 相比原始实现增强了容错：结构异常（缺 <html>/<head>/<body>）时仍能取到正文与标题。


# --- Public Vars ---

## 文档来源 URL（由解析器或调用方填写）
var source_url: String = ""

## 原始 HTML 文本
var raw_html: String = ""


# --- Built-in Functions ---

func _init() -> void:
	node_type = NodeType.DOCUMENT
	tag_name = "#document"


# --- Public Functions ---

## 返回 <html> 元素（缺失时退化为首个元素子节点）
func get_document_element() -> AIChatHtmlNode:
	for child in children:
		if child.is_element() and child.tag_name == "html":
			return child
	for child in children:
		if child.is_element():
			return child
	return null


## 返回 <head> 元素
func get_head() -> AIChatHtmlNode:
	var root: AIChatHtmlNode = get_document_element()
	if root == null:
		return null
	for child in root.children:
		if child.is_element() and child.tag_name == "head":
			return child
	return null


## 返回 <body> 元素（缺失时退化为文档元素，保证正文仍可提取）
func get_body() -> AIChatHtmlNode:
	var root: AIChatHtmlNode = get_document_element()
	if root != null:
		for child in root.children:
			if child.is_element() and child.tag_name == "body":
				return child
	for node in walk_elements():
		if node.tag_name == "body":
			return node
	return root


## 读取页面标题：<head> 内 <title> → 全树 <title> → og:title
func get_title() -> String:
	var head: AIChatHtmlNode = get_head()
	if head != null:
		for child in head.children:
			if child.is_element() and child.tag_name == "title":
				var head_title: String = child.get_text_content().strip_edges()
				if not head_title.is_empty():
					return head_title
	for node in walk_elements():
		if node.tag_name == "title":
			var title: String = node.get_text_content().strip_edges()
			if not title.is_empty():
				return title
	return _find_meta_content("og:title")


# --- Private Functions ---

# 按 property / name 查找 <meta> 的 content 值
func _find_meta_content(p_key: String) -> String:
	var key: String = p_key.to_lower()
	for node in walk_elements():
		if node.tag_name != "meta":
			continue
		var property: String = node.get_attribute("property").to_lower()
		var meta_name: String = node.get_attribute("name").to_lower()
		if property == key or meta_name == key:
			var content: String = node.get_attribute("content").strip_edges()
			if not content.is_empty():
				return content
	return ""
