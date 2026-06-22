@tool
class_name WebFetchContentTool
extends AiTool

## 网页内容抓取与提取工具
##
## 使用 HTTPClient（无需场景树）+ Godot DOMParser 的 HTMLParser 实现。
## 支持 CSS 选择器定位内容和自动内容检测。
## 本工具依赖第三方 Godot 插件 Godot DOM Parser 运行。

# --- Enums / Constants ---

const REQUEST_TIMEOUT: float = 30.0
const POLL_DELAY: float = 0.01

# 自动检测时的候选选择器（按优先级降序）
const _AUTO_SELECTORS: Array[String] = [
	"article",
	"[role=main]",
	".post-content", ".article-content", ".entry-content",
	"#content", "#main", "#article",
	"main",
	"body"
]

# 内容提取时需移除的"噪音"标签
const _NOISE_TAGS: Array[String] = [
	"script", "style", "nav", "footer", "header",
	"aside", "noscript", "iframe", "svg"
]


func _init() -> void:
	tool_name = "web_fetch_content"
	tool_description = "Fetches a web page and extracts its main text content. NOTE: ALWAYS use `search_godot_api` first to read Godot API doc."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"url": {
				"type": "string",
				"description": "The URL of the web page to fetch."
			},
			"content_selector": {
				"type": "string",
				"description": "Optional CSS selector to pinpoint the content area. " + \
					"Examples: 'article', '#main-content', '.post-body', 'div.content p'. " + \
					"If empty, the tool will auto-detect the main content."
			},
			"max_length": {
				"type": "integer",
				"description": "Maximum character length of the returned text. Default: 5000.",
				"default": 5000
			},
			"include_links": {
				"type": "boolean",
				"description": "If true, keeps hyperlink text visible in output. Default: false.",
				"default": false
			}
		},
		"required": ["url"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var url: String = p_args.get("url", "").strip_edges()
	if url.is_empty():
		return {"success": false, "data": "Error: URL cannot be empty."}
	
	# 基础 URL 校验
	if not url.begins_with("http://") and not url.begins_with("https://"):
		url = "https://" + url
	
	var selector: String = p_args.get("content_selector", "").strip_edges()
	var max_length: int = p_args.get("max_length", 5000)
	var include_links: bool = p_args.get("include_links", false)
	
	# 1. 获取 HTML
	var html: String = await _fetch_html(url)
	if html.is_empty():
		return {"success": false, "data": "Error: Failed to fetch content from URL."}
	
	# 2. 解析 HTML 为 DOM
	var doc: DOMDocument = HTMLParser.parse(html)
	if not doc:
		return {"success": false, "data": "Error: Failed to parse HTML."}
	
	# 3. 定位内容节点
	var content_node: DOMNode = _locate_content(doc, selector)
	if not content_node:
		return {"success": false, "data": "Error: Could not locate content on the page."}
	
	# 4. 清理噪音元素
	_strip_noise(content_node)
	
	# 5. 提取文本
	var raw_text: String = _extract_text(content_node, include_links)
	
	# 6. 清理空白
	raw_text = _clean_whitespace(raw_text)
	
	# 7. 截断
	if raw_text.length() > max_length:
		raw_text = raw_text.left(max_length) + "\n\n[...truncated at %d characters]" % max_length
	
	var meta: String = ""
	var title: String = doc.get_title()
	if not title.is_empty():
		meta = "Page Title: %s\n\n" % title
	
	return {"success": true, "data": meta + raw_text}


# --- Private: Network ---

func _fetch_html(p_url: String) -> String:
	var client := HTTPClient.new()
	
	# 解析 URL
	var is_https: bool = p_url.begins_with("https://")
	var url_body: String = p_url.trim_prefix("http://").trim_prefix("https://")
	var host_end: int = url_body.find("/")
	var host: String = url_body.substr(0, host_end) if host_end != -1 else url_body
	var path: String = url_body.substr(host_end) if host_end != -1 else "/"
	var port: int = 443 if is_https else 80
	
	if ":" in host:
		var parts: PackedStringArray = host.split(":")
		host = parts[0]
		port = int(parts[1])
	
	# 连接
	var tls_opts: TLSOptions = TLSOptions.client() if is_https else null
	var err: Error = client.connect_to_host(host, port, tls_opts)
	if err != OK:
		client.close()
		return ""
	
	var timer: float = 0.0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return ""
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return ""
	
	# 请求
	err = client.request(HTTPClient.METHOD_GET, path, ["User-Agent: GodotAIChat/1.0"])
	if err != OK:
		client.close()
		return ""
	
	timer = 0.0
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return ""
	
	# 检查响应码
	if client.get_response_code() != 200:
		client.close()
		return ""
	
	# 读取响应体
	var response := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		response.append_array(client.read_response_body_chunk())
		if client.get_status() == HTTPClient.STATUS_BODY:
			await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
	
	client.close()
	
	# 尝试 UTF-8 解码，失败则 fallback 到 ASCII
	var text: String = response.get_string_from_utf8()
	if text.is_empty() and not response.is_empty():
		text = response.get_string_from_ascii()
	return text


# --- Private: Content Location ---

func _locate_content(p_doc: DOMDocument, p_selector: String) -> DOMNode:
	# 如果提供了选择器，优先使用
	if not p_selector.is_empty():
		var node: DOMNode = p_doc.query_selector(p_selector)
		if node:
			return node
	
	# 自动检测
	for sel in _AUTO_SELECTORS:
		var node: DOMNode = p_doc.query_selector(sel)
		if node:
			return node
	
	return null


# --- Private: Text Extraction ---

func _strip_noise(p_node: DOMNode) -> void:
	# 移除噪音标签
	for tag in _NOISE_TAGS:
		var elements: Array[DOMNode] = p_node.get_elements_by_tag_name(tag)
		for el in elements:
			el.remove()
	
	# 移除注释
	var to_remove: Array[DOMNode] = []
	for child in p_node.children:
		if child.node_type == DOMNode.NodeType.COMMENT:
			to_remove.append(child)
	for child in to_remove:
		child.remove()


func _extract_text(p_node: DOMNode, p_keep_links: bool) -> String:
	var parts: Array[String] = []
	
	for child in p_node.children:
		match child.node_type:
			DOMNode.NodeType.TEXT:
				var t := child.text.strip_edges()
				if not t.is_empty():
					parts.append(t)
			
			DOMNode.NodeType.ELEMENT:
				var tag := child.tag_name
				
				# 块级元素：换行分隔
				if tag in ["p", "div", "h1", "h2", "h3", "h4", "h5", "h6",
						"li", "blockquote", "pre", "hr", "br", "tr", "section"]:
					var inner := _extract_text(child, p_keep_links)
					if not inner.is_empty():
						parts.append(inner)
				
				# 链接：可选择保留
				elif tag == "a" and p_keep_links:
					var href := child.get_attribute("href", "")
					var inner := _extract_text(child, p_keep_links)
					if not inner.is_empty():
						if not href.is_empty():
							parts.append("%s (%s)" % [inner, href])
						else:
							parts.append(inner)
				
				# 列表项：加前缀
				elif tag == "li":
					var inner := _extract_text(child, p_keep_links)
					if not inner.is_empty():
						parts.append("- " + inner)
				
				# 表格单元格：制表符分隔
				elif tag in ["td", "th"]:
					var inner := _extract_text(child, p_keep_links)
					parts.append(inner)
				
				# 图片：alt 文本
				elif tag == "img":
					var alt := child.get_attribute("alt", "")
					if not alt.is_empty():
						parts.append("[Image: %s]" % alt)
				
				else:
					# 其他行内元素：递归提取
					var inner := _extract_text(child, p_keep_links)
					if not inner.is_empty():
						parts.append(inner)

	return "\n".join(parts)


func _clean_whitespace(p_text: String) -> String:
	# 合并多个换行为两个
	var result := ""
	var lines := p_text.split("\n")
	var prev_empty: bool = false
	for line in lines:
		var trimmed := line.strip_edges()
		if trimmed.is_empty():
			if not prev_empty:
				result += "\n\n"
				prev_empty = true
		else:
			result += trimmed + "\n"
			prev_empty = false
	return result.strip_edges()
