@tool
extends AiTool

## 网页内容抓取与提取工具
##
## 使用 HTTPClient（无需场景树）+ Godot DOMParser 的 HTMLParser 实现。
## 支持 CSS 选择器定位内容和自动内容检测。
## 本工具依赖第三方 Godot 插件 Godot DOM Parser 运行。

# --- Enums / Constants ---

const REQUEST_TIMEOUT: float = 30.0
const POLL_DELAY: float = 0.01
const MAX_REDIRECTS: int = 5

# 模拟浏览器 UA，避免被 Cloudflare 等 WAF 拦截
const _BROWSER_UA: String = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

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
	tool_name = "fetch_web_content"
	tool_description = "Fetches a web page and extracts its main text content. WARNING: DO NNOT USE THIS TOOL TO GET Online Godot Doc."


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


func execute(p_args: Dictionary) -> ToolResult:
	var url: String = p_args.get("url", "").strip_edges()
	if url.is_empty():
		return ToolResult.fail("Error: URL cannot be empty.")
	
	# 基础 URL 校验
	if not url.begins_with("http://") and not url.begins_with("https://"):
		url = "https://" + url
	
	var selector: String = p_args.get("content_selector", "").strip_edges()
	var max_length: int = p_args.get("max_length", 5000)
	var include_links: bool = p_args.get("include_links", false)
	
	# 1. 获取内容（自动跟随重定向）
	var result: Dictionary = await _fetch_url(url)
	if not result.get("success", false):
		return ToolResult.fail("Error: %s" % result.get("error", "Failed to fetch content from URL."))
	
	var body: String = result.get("body", "")
	var content_type: String = result.get("content_type", "")
	
	# 1.5 JSON 等非 HTML 响应直接返回原始文本（如 GitHub API）
	var stripped: String = body.strip_edges()
	if content_type.contains("json") or stripped.begins_with("{") or stripped.begins_with("["):
		return ToolResult.ok(_truncate(body, max_length))
	
	# 2. 解析 HTML 为 DOM
	var doc: DOMDocument = HTMLParser.parse(body)
	if not doc:
		return ToolResult.fail("Error: Failed to parse HTML.")
	
	# 3. 定位内容节点
	var content_node: DOMNode = _locate_content(doc, selector)
	if not content_node:
		return ToolResult.fail("Error: Could not locate content on the page.")
	
	# 4. 清理噪音元素
	_strip_noise(content_node)
	
	# 5. 提取文本
	var raw_text: String = _extract_text(content_node, include_links)
	
	# 6. 清理空白
	raw_text = _clean_whitespace(raw_text)
	
	# 7. 截断
	raw_text = _truncate(raw_text, max_length)
	
	var meta: String = ""
	var title: String = doc.get_title()
	if not title.is_empty():
		meta = "Page Title: %s\n\n" % title
	
	return ToolResult.ok(meta + raw_text)


# --- Private: Network ---

# 发起 GET 请求并自动跟随重定向（最多 MAX_REDIRECTS 跳）
# [return]: {success: bool, error?: String, body?: String, content_type?: String}
func _fetch_url(p_url: String) -> Dictionary:
	var current_url: String = p_url
	for _i in range(MAX_REDIRECTS + 1):
		var resp: Dictionary = await _http_get(current_url)
		if not resp.get("success", false):
			return resp
		
		var code: int = resp.get("code", 0)
		if code >= 300 and code < 400:
			var location: String = resp.get("location", "").strip_edges()
			if location.is_empty():
				return {"success": false, "error": "HTTP %d redirect without Location header." % code}
			var next_url: String = _resolve_redirect(current_url, location)
			if next_url.is_empty():
				return {"success": false, "error": "Invalid redirect Location: %s" % location}
			current_url = next_url
			continue
		
		if code != 200:
			return {"success": false, "error": "HTTP %d for %s" % [code, current_url]}
		
		return resp
	
	return {"success": false, "error": "Too many redirects (>%d)." % MAX_REDIRECTS}


# 单次 HTTP GET（不跟随重定向，3xx 时仅返回 Location）
func _http_get(p_url: String) -> Dictionary:
	var client := HTTPClient.new()
	
	# 解析 URL（含端口 / query / fragment）
	var parsed := _parse_url(p_url)
	if parsed.is_empty():
		client.close()
		return {"success": false, "error": "Invalid URL: %s" % p_url}
	
	var tls_opts: TLSOptions = TLSOptions.client() if parsed.https else null
	var err: Error = client.connect_to_host(parsed.host, parsed.port, tls_opts)
	if err != OK:
		client.close()
		return {"success": false, "error": "Connection init failed (%d)" % err}
	
	# 连接 / DNS
	var timer: float = 0.0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"success": false, "error": "Connection timeout for %s" % p_url}
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return {"success": false, "error": "Connection failed (status: %d)" % client.get_status()}
	
	# 发送请求
	var headers: PackedStringArray = [
		"User-Agent: " + _BROWSER_UA,
		"Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
		"Accept-Language: en-US,en;q=0.9",
		"Accept-Encoding: identity",
	]
	err = client.request(HTTPClient.METHOD_GET, parsed.path, headers)
	if err != OK:
		client.close()
		return {"success": false, "error": "Request failed (%d)" % err}
	
	# 等待响应头
	timer = 0.0
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"success": false, "error": "Request timeout for %s" % p_url}
	
	var code: int = client.get_response_code()
	
	# 3xx：提取 Location 后返回（不读取 body）
	if code >= 300 and code < 400:
		var location := ""
		for h in client.get_response_headers():
			if h.to_lower().begins_with("location:"):
				location = h.substr(9).strip_edges()
				break
		
		client.close()
		return {"success": true, "code": code, "location": location}
	
	# 非 2xx
	if code < 200 or code >= 300:
		client.close()
		return {"success": false, "error": "HTTP %d for %s" % [code, p_url]}
	
	# 读取响应体（带超时）
	var response := PackedByteArray()
	timer = 0.0
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		response.append_array(client.read_response_body_chunk())
		if client.get_status() == HTTPClient.STATUS_BODY:
			await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
			timer += POLL_DELAY
			if timer >= REQUEST_TIMEOUT:
				client.close()
				return {"success": false, "error": "Response body read timeout for %s" % p_url}
	
	# Content-Type
	var content_type := ""
	for h in client.get_response_headers():
		if h.to_lower().begins_with("content-type:"):
			content_type = h.substr(13).strip_edges().to_lower()
			break
	
	client.close()
	
	# 解码：优先 UTF-8，失败 fallback ASCII
	var text: String = response.get_string_from_utf8()
	if text.is_empty() and not response.is_empty():
		text = response.get_string_from_ascii()
	
	return {
		"success": true,
		"code": code,
		"body": text,
		"content_type": content_type,
	}


# 解析 URL（支持端口、query、fragment）
func _parse_url(p_url: String) -> Dictionary:
	var url := p_url.strip_edges()
	if not url.begins_with("http://") and not url.begins_with("https://"):
		url = "https://" + url
	
	var https := url.begins_with("https://")
	var body := url.trim_prefix("http://").trim_prefix("https://")
	
	# 剥离 fragment（#...）
	var hash_pos := body.find("#")
	if hash_pos != -1:
		body = body.substr(0, hash_pos)
	
	# 分离 host 与 path（path 保留 query string）
	var path := "/"
	var slash_pos := body.find("/")
	if slash_pos != -1:
		path = body.substr(slash_pos)
		body = body.substr(0, slash_pos)
	
	# 分离端口
	var port := 443 if https else 80
	if ":" in body:
		var parts: PackedStringArray = body.split(":")
		if parts.size() == 2 and parts[1].is_valid_int():
			body = parts[0]
			port = parts[1].to_int()
	
	if body.is_empty():
		return {}
	
	return {"host": body, "port": port, "path": path, "https": https}


# 解析重定向 Location 为绝对 URL
func _resolve_redirect(p_current: String, p_location: String) -> String:
	var loc := p_location.strip_edges()
	if loc.is_empty():
		return ""
	
	# 绝对 URL
	if loc.begins_with("http://") or loc.begins_with("https://"):
		return loc
	
	# 协议相对（//host/path）
	if loc.begins_with("//"):
		var proto := p_current.get_slice(":", 0)
		return proto + ":" + loc
	
	# 根相对（/path）
	if loc.begins_with("/"):
		var parsed := _parse_url(p_current)
		if parsed.is_empty():
			return ""
		var proto := "https" if parsed.https else "http"
		return "%s://%s%s" % [proto, parsed.host, loc]
	
	# 相对路径（./x 或 x/y）
	var base := p_current.get_slice("?", 0)  # 去掉 query
	var idx := base.rfind("/")
	if idx != -1:
		return base.substr(0, idx + 1) + loc
	return base + "/" + loc


# 文本截断
func _truncate(p_text: String, p_max_length: int) -> String:
	if p_text.length() > p_max_length:
		return p_text.left(p_max_length) + "\n\n[...truncated at %d characters]" % p_max_length
	return p_text


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
						"blockquote", "pre", "hr", "br", "tr", "section"]:
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
