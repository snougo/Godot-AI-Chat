extends AiTool

## 网页内容抓取与提取工具
##
## 使用 HTTPClient（无需场景树）+ 内建 HTML 解析器实现，不依赖任何第三方插件。
## 支持 CSS 选择器定位内容、自动正文检测、字符集嗅探、Content-Encoding 解压、
## 分阶段超时与短期缓存。


# --- Constants ---

const CONNECT_TIMEOUT: float = 10.0
const HEADER_TIMEOUT: float = 15.0
const BODY_TIMEOUT: float = 25.0
const POLL_DELAY: float = 0.01
const MAX_REDIRECTS: int = 5
const MAX_RETRIES: int = 1

## 响应体大小上限（字节），同时用于解压后的输出上限保护
const MAX_BODY_BYTES: int = 6 * 1024 * 1024

# 同一 URL 的抓取结果缓存时长（秒）与条目数上限
const CACHE_TTL_SEC: float = 300.0
const CACHE_MAX_ENTRIES: int = 4
const CACHE_ENTRY_MAX_CHARS: int = 512 * 1024

## 正文少于该字符数即视为抓取失败（反爬 / 需登录 / JS 渲染）
## 若真实短内容被误判为失败，调小此值即可
const MIN_CONTENT_CHARS: int = 200

# 正文短于该值且页面标记很大时，提示可能是 JS 渲染页面
const SPARSE_CONTENT_CHARS: int = 1000
const SPARSE_PAGE_BYTES: int = 200000

## 失败信息中携带的正文预览长度
const PREVIEW_CHARS: int = 300

## 反爬 / 风控页面的特征标记（仅用于失败路径，不会误伤正常抓取）
## 匹配对象是"标题 + 正文前 4KB"，全部小写
const ANTIBOT_MARKERS: Array[String] = [
	"验证码", "请输入验证码", "安全验证", "人机验证", "滑动验证",
	"访问过于频繁", "访问受限", "just a moment", "attention required",
	"checking your browser", "enable javascript and cookies to continue",
	"cf-browser-verification", "verify you are human", "ddos protection",
	"robot check", "access denied", "captcha"
]

# 自动正文检测：候选标签 / 候选 id·class 关键词
const CANDIDATE_TAGS: Array[String] = ["article", "main", "body"]
const CANDIDATE_KEYWORDS: Array[String] = [
	"post-content", "article-content", "entry-content", "post-body",
	"markdown-body", "doc-content", "content", "main", "article", "post"
]

# 正文候选打分权重
const PARAGRAPH_BONUS: float = 40.0
const MIN_CANDIDATE_CHARS: int = 120
const MAX_LINK_DENSITY: float = 0.9
const MAX_PARAGRAPHS_SCORED: int = 20

# 链接块过滤：块内链接文本占比 ≥ 该值、链接数 ≥ _MIN_BLOCK_LINK_COUNT、
# 文本 ≥ MIN_BLOCK_CHARS 时，整块从 DOM 摘除（导航 / 相关推荐 / 页脚）
const MIN_BLOCK_LINK_DENSITY: float = 0.5
const MIN_BLOCK_LINK_COUNT: int = 3
const MIN_BLOCK_CHARS: int = 50

## 正文节点自身链接密度 ≥ 该值时视为"目录页 / 列表页"，禁用过滤以免清空正文
const MAX_CONTENT_LINK_DENSITY: float = 0.6

## 模拟浏览器 UA，避免被 Cloudflare 等 WAF 直接拦截
const BROWSER_UA: String = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

## 解析期直接丢弃的噪音标签（整棵子树不进 DOM）
const NOISE_TAGS: Array[String] = [
	"script", "style", "nav", "footer", "header", "aside",
	"noscript", "iframe", "svg", "template", "form", "button", "select", "canvas"
]

## 需要折叠为普通空格的"类空格"字符集合（正则字符类内容）
## 覆盖：ASCII 空白、不换行空格 U+00A0、Unicode 空格 U+2000–U+200B、U+202F、U+205F、
## 全角空格 U+3000、零宽 BOM U+FEFF
const BLANK_CHARS: String = " \\t\\f\\v\\x{00A0}\\x{2000}-\\x{200B}\\x{202F}\\x{205F}\\x{3000}\\x{FEFF}"


# --- Private Vars ---

# 抓取结果缓存：{ url: {"time": float, "response": Dictionary} }
static var _fetch_cache: Dictionary = {}


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "fetch_web_content"
	tool_description = "Fetches a web page and extracts its main text content. JavaScript-rendered pages are not supported."


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
	var url: String = str(p_args.get("url", "")).strip_edges()
	
	if url.is_empty():
		return ToolResult.fail("Error: URL cannot be empty.")
	if not url.begins_with("http://") and not url.begins_with("https://"):
		url = "https://" + url
	
	var selector: String = str(p_args.get("content_selector", "")).strip_edges()
	
	var max_length: int = int(p_args.get("max_length", 5000))
	if max_length <= 0:
		max_length = 5000
	
	var include_links: bool = bool(p_args.get("include_links", false))
	
	# 1. 获取内容（自动跟随重定向）
	var fetched: Dictionary = await _fetch_with_redirects(url)
	if not fetched.get("success", false):
		return ToolResult.fail("Error: %s" % str(fetched.get("error", "Failed to fetch content from URL.")))
	
	var body: String = str(fetched.get("body", ""))
	var content_type: String = str(fetched.get("content_type", ""))
	var final_url: String = str(fetched.get("url", url))
	var status_code: int = int(fetched.get("code", 0))
	
	if body.strip_edges().is_empty():
		return ToolResult.fail(_build_short_content_error(final_url, status_code, content_type, "", body, ""))
	
	# 2. 非 HTML 响应处理
	var kind: String = _classify_content_type(content_type)
	if kind == "pdf":
		return ToolResult.fail("Error: The URL points to a PDF document, which this tool cannot extract. Try a documentation page that hosts the content as HTML.")
	if kind == "image":
		return ToolResult.fail("Error: The URL points to an image, which this tool cannot extract.")
	
	var stripped: String = body.strip_edges()
	if kind == "text" or stripped.begins_with("{") or stripped.begins_with("["):
		return ToolResult.ok(_truncate(body, max_length))
	
	# 3. 解析 HTML（噪音标签解析期丢弃）
	var document: AIChatHtmlDocument = AIChatHtmlParser.parse(body, PackedStringArray(NOISE_TAGS))
	var content_node: AIChatHtmlNode = _locate_content(document, selector)
	if content_node == null and not selector.is_empty():
		# 选择器可能命中了被丢弃的噪音标签，退化重解析一次
		document = AIChatHtmlParser.parse(body)
		content_node = _locate_content(document, selector)
	if content_node == null:
		return ToolResult.fail("Error: Could not locate content on the page.")
	
	# 4. 剔除"链接块"（导航 / 相关推荐 / 页脚等几乎全是链接的容器）
	_prune_link_blocks(content_node)
	
	# 5. 提取文本
	var title: String = document.get_title()
	var base_url: String = _find_base_url(document, final_url)
	var raw_text: String = _shrink_whitespace(_extract_text(content_node, include_links, base_url))
	
	# 6. 正文过短 → 判定为抓取失败，并给出可诊断的原因（反爬 / 需登录 / JS 渲染）
	if raw_text.length() < MIN_CONTENT_CHARS:
		return ToolResult.fail(_build_short_content_error(final_url, status_code, content_type, title, body, raw_text))
	
	raw_text = _truncate(raw_text, max_length)
	
	# 7. 组装输出
	var head_parts: Array[String] = []
	if not title.is_empty():
		head_parts.append("Page Title: %s" % title)
	if final_url != url:
		head_parts.append("Source URL: %s" % final_url)
	if raw_text.length() < SPARSE_CONTENT_CHARS and body.length() > SPARSE_PAGE_BYTES:
		head_parts.append("Note: the extracted text is very short while the page markup is large; this page likely renders its content with JavaScript, which this tool cannot execute.")
	
	if head_parts.is_empty():
		return ToolResult.ok(raw_text)
	
	return ToolResult.ok("\n".join(head_parts) + "\n\n" + raw_text)


# --- Private Functions: Network ---

# 发起 GET 请求并自动跟随重定向
# [return]: {success: bool, error?: String, body?: String, content_type?: String, url?: String}
func _fetch_with_redirects(p_url: String) -> Dictionary:
	var current_url: String = p_url
	var visited: Array[String] = []
	
	for _hop in range(MAX_REDIRECTS + 1):
		if current_url in visited:
			return {"success": false, "error": "Redirect loop detected at %s" % current_url}
		visited.append(current_url)
		
		var response: Dictionary = await _request_with_retry(current_url)
		if not response.get("success", false):
			return response
		
		var code: int = int(response.get("code", 0))
		if code >= 300 and code < 400:
			var location: String = str(response.get("location", "")).strip_edges()
			if location.is_empty():
				return {"success": false, "error": "HTTP %d redirect without Location header." % code}
			
			var next_url: String = _resolve_url(current_url, location)
			if next_url.is_empty():
				return {"success": false, "error": "Invalid redirect Location: %s" % location}
			
			current_url = next_url
			continue
		
		response["url"] = current_url
		return response
	
	return {"success": false, "error": "Too many redirects (>%d)." % MAX_REDIRECTS}


# 带缓存与有限重试的单次请求
func _request_with_retry(p_url: String) -> Dictionary:
	var cached: Dictionary = _read_cache(p_url)
	if not cached.is_empty():
		return cached
	
	var last_error: String = "Unknown network error."
	
	for attempt in range(MAX_RETRIES + 1):
		var response: Dictionary = await _http_get(p_url)
		if response.get("success", false):
			_write_cache(p_url, response)
			return response
		
		last_error = str(response.get("error", "Unknown network error."))
		if not response.get("retryable", false):
			return response
		
		if attempt < MAX_RETRIES:
			await _sleep(0.4 * float(attempt + 1))
	
	return {"success": false, "error": last_error}


# 单次 HTTP GET（不跟随重定向，3xx 仅返回 Location）
func _http_get(p_url: String) -> Dictionary:
	var parsed: Dictionary = _parse_url(p_url)
	if parsed.is_empty():
		return {"success": false, "error": "Invalid URL: %s" % p_url, "retryable": false}
	
	var client := HTTPClient.new()
	var tls_options: TLSOptions = TLSOptions.client() if parsed["https"] else null
	var error: Error = client.connect_to_host(parsed["host"], parsed["port"], tls_options)
	if error != OK:
		client.close()
		return {"success": false, "error": "Connection init failed (%d) for %s" % [error, p_url], "retryable": true}
	
	# 阶段 1：DNS + TCP + TLS
	if not await _poll_while_status_in(client, [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING], CONNECT_TIMEOUT):
		client.close()
		return {"success": false, "error": "Connection timeout for %s" % p_url, "retryable": true}
	
	var status: int = client.get_status()
	if status != HTTPClient.STATUS_CONNECTED:
		client.close()
		return {
			"success": false,
			"error": "Connection failed (%s) for %s" % [_status_name(status), p_url],
			"retryable": true
		}
	
	# 阶段 2：发送请求并等待响应头
	var headers: PackedStringArray = [
		"User-Agent: " + BROWSER_UA,
		"Accept: text/html,application/xhtml+xml,application/json;q=0.9,text/plain;q=0.8,*/*;q=0.7",
		"Accept-Language: en-US,en;q=0.9",
		"Accept-Encoding: gzip, deflate, br",
	]
	
	error = client.request(HTTPClient.METHOD_GET, parsed["path"], headers)
	if error != OK:
		client.close()
		return {"success": false, "error": "Request failed (%d) for %s" % [error, p_url], "retryable": true}
	
	if not await _poll_while_status_in(client, [HTTPClient.STATUS_REQUESTING], HEADER_TIMEOUT):
		client.close()
		return {"success": false, "error": "Request timeout for %s" % p_url, "retryable": true}
	
	var code: int = client.get_response_code()
	var response_headers: PackedStringArray = client.get_response_headers()
	var content_type: String = _get_header(response_headers, "content-type")
	var content_encoding: String = _get_header(response_headers, "content-encoding")
	
	# 3xx：只取 Location，不读 body
	if code >= 300 and code < 400:
		var location: String = _get_header(response_headers, "location")
		client.close()
		return {"success": true, "code": code, "location": location}
	
	if code < 200 or code >= 300:
		client.close()
		return {
			"success": false,
			"error": "HTTP %d for %s" % [code, p_url],
			"retryable": code >= 500
		}
	
	# 预检声明长度，避免无谓的大对象读取
	var declared_length: int = int(_get_header(response_headers, "content-length"))
	if declared_length > MAX_BODY_BYTES:
		client.close()
		return {
			"success": false,
			"error": "Response body exceeds the %d bytes limit for %s" % [MAX_BODY_BYTES, p_url],
			"retryable": false
		}
	
	# 阶段 3：读取正文（带大小上限与超时）
	var raw_bytes := PackedByteArray()
	var elapsed: float = 0.0
	
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk: PackedByteArray = client.read_response_body_chunk()
		if not chunk.is_empty():
			if raw_bytes.size() + chunk.size() > MAX_BODY_BYTES:
				client.close()
				return {
					"success": false,
					"error": "Response body exceeds the %d bytes limit for %s" % [MAX_BODY_BYTES, p_url],
					"retryable": false
				}
			
			raw_bytes.append_array(chunk)
		
		if client.get_status() == HTTPClient.STATUS_BODY:
			await _sleep(POLL_DELAY)
			
			elapsed += POLL_DELAY
			if elapsed >= BODY_TIMEOUT:
				client.close()
				return {"success": false, "error": "Response body read timeout for %s" % p_url, "retryable": true}
	
	client.close()
	
	# 阶段 4：解压 + 字符集解码
	var payload: PackedByteArray = _decompress_body(raw_bytes, content_encoding)
	var charset: String = _detect_charset(payload, content_type)
	
	return {
		"success": true,
		"code": code,
		"body": _decode_body(payload, charset),
		"content_type": content_type,
	}


# 轮询直至状态离开 p_wait_states；返回 true 表示正常退出，false 表示超时
func _poll_while_status_in(p_client: HTTPClient, p_wait_states: Array, p_timeout: float) -> bool:
	var elapsed: float = 0.0
	
	while p_client.get_status() in p_wait_states:
		p_client.poll()
		if not p_client.get_status() in p_wait_states:
			return true
		
		await _sleep(POLL_DELAY)
		elapsed += POLL_DELAY
		
		if elapsed >= p_timeout:
			return false
	
	return true


# 解析重定向 / 链接用的绝对 URL
func _resolve_url(p_base: String, p_reference: String) -> String:
	var reference: String = p_reference.strip_edges()
	if reference.is_empty():
		return ""
	if reference.begins_with("http://") or reference.begins_with("https://"):
		return reference
	if reference.begins_with("//"):
		var scheme: String = p_base.get_slice(":", 0)
		if scheme.is_empty():
			scheme = "https"
		return scheme + ":" + reference
	
	if p_base.is_empty():
		return reference
	
	var parsed_base: Dictionary = _parse_url(p_base)
	if parsed_base.is_empty():
		return reference
	
	var base_scheme: String = "https" if parsed_base["https"] else "http"
	var authority: String = parsed_base["authority"]
	if reference.begins_with("#"):
		return "%s://%s%s" % [base_scheme, authority, parsed_base["path"].get_slice("#", 0)]
	if reference.begins_with("/"):
		return "%s://%s%s" % [base_scheme, authority, reference]
	
	var base_path: String = parsed_base["path"].get_slice("?", 0)
	if reference.begins_with("?"):
		return "%s://%s%s%s" % [base_scheme, authority, base_path, reference]
	
	var last_slash: int = base_path.rfind("/")
	var directory: String = base_path.substr(0, last_slash + 1) if last_slash != -1 else "/"
	
	return "%s://%s%s%s" % [base_scheme, authority, directory, reference]


# 解析 URL（支持端口 / query / fragment）
func _parse_url(p_url: String) -> Dictionary:
	var url: String = p_url.strip_edges()
	if not url.begins_with("http://") and not url.begins_with("https://"):
		url = "https://" + url
	
	var is_https: bool = url.begins_with("https://")
	var remainder: String = url.trim_prefix("http://").trim_prefix("https://")
	
	# 剥离 fragment
	var hash_index: int = remainder.find("#")
	if hash_index != -1:
		remainder = remainder.substr(0, hash_index)
	
	# 分离 host 与 path（path 保留 query string）
	var path: String = "/"
	var slash_index: int = remainder.find("/")
	if slash_index != -1:
		path = remainder.substr(slash_index)
		remainder = remainder.substr(0, slash_index)
	
	# 分离端口
	var authority: String = remainder
	var port: int = 443 if is_https else 80
	var colon_index: int = remainder.rfind(":")
	if colon_index != -1:
		var port_text: String = remainder.substr(colon_index + 1)
		if port_text.is_valid_int():
			remainder = remainder.substr(0, colon_index)
			port = port_text.to_int()
	
	if remainder.is_empty():
		return {}
	
	return {"host": remainder, "port": port, "path": path, "https": is_https, "authority": authority}


# --- Private Functions: Decoding ---

# 按 Content-Encoding 逆序解压（支持 gzip / deflate / br）
func _decompress_body(p_data: PackedByteArray, p_content_encoding: String) -> PackedByteArray:
	if p_data.is_empty() or p_content_encoding.is_empty():
		return p_data
	
	var encodings: PackedStringArray = p_content_encoding.to_lower().split(",", false)
	var result: PackedByteArray = p_data
	
	for index in range(encodings.size() - 1, -1, -1):
		var mode: int = -1
		match encodings[index].strip_edges():
			"gzip", "x-gzip":
				mode = FileAccess.COMPRESSION_GZIP
			"br":
				mode = FileAccess.COMPRESSION_BROTLI
			"deflate":
				mode = FileAccess.COMPRESSION_DEFLATE
		
		if mode == -1:
			continue
		
		var decoded: PackedByteArray = result.decompress_dynamic(MAX_BODY_BYTES, mode)
		if decoded.is_empty():
			# 解压失败（例如服务器实际未压缩）——回退原始数据
			return p_data
		
		result = decoded
	
	return result


# 字符集嗅探：Content-Type → BOM → <meta charset> → 默认 UTF-8
func _detect_charset(p_bytes: PackedByteArray, p_content_type: String) -> String:
	var from_header: String = _extract_charset(p_content_type)
	if not from_header.is_empty():
		return from_header
	
	if p_bytes.size() >= 3 and p_bytes[0] == 0xEF and p_bytes[1] == 0xBB and p_bytes[2] == 0xBF:
		return "utf-8"
	if p_bytes.size() >= 2 and p_bytes[0] == 0xFF and p_bytes[1] == 0xFE:
		return "utf-16le"
	if p_bytes.size() >= 2 and p_bytes[0] == 0xFE and p_bytes[1] == 0xFF:
		return "utf-16be"
	
	# HTML meta 嗅探：前 2KB（各主流编码的 ASCII 区段兼容）
	var head_length: int = mini(p_bytes.size(), 2048)
	var head_text: String = p_bytes.slice(0, head_length).get_string_from_ascii().to_lower()
	var from_meta: String = _extract_charset(head_text)
	if not from_meta.is_empty():
		return from_meta
	
	return "utf-8"


# 从 "charset=xxx" 片段中取出编码名
func _extract_charset(p_text: String) -> String:
	var index: int = p_text.to_lower().find("charset")
	if index == -1:
		return ""
	
	var cursor: int = index + 7
	var length: int = p_text.length()
	
	while cursor < length and (p_text[cursor] == " " or p_text[cursor] == "\t"):
		cursor += 1
	
	if cursor < length and p_text[cursor] == "=":
		cursor += 1
	
	while cursor < length and (p_text[cursor] == " " or p_text[cursor] == "\t"):
		cursor += 1
	
	var quote: String = ""
	if cursor < length and (p_text[cursor] == "\"" or p_text[cursor] == "'"):
		quote = p_text[cursor]
		cursor += 1
	
	var start: int = cursor
	while cursor < length:
		var character: String = p_text[cursor]
		if quote.is_empty():
			if character in [";", ">", " ", "\t", "\"", "'", "/"]:
				break
		elif character == quote:
			break
		cursor += 1
	
	return p_text.substr(start, cursor - start).strip_edges()


# 按编码名解码字节流
func _decode_body(p_bytes: PackedByteArray, p_charset: String) -> String:
	if p_bytes.is_empty():
		return ""
	
	var charset: String = p_charset.strip_edges().to_lower().trim_prefix("\"").trim_suffix("\"")
	if charset.is_empty():
		charset = "utf-8"
	
	match charset:
		"utf-8", "utf8":
			return _decode_utf8(p_bytes)
		"utf-16", "utf-16le", "utf-16be", "utf16":
			var utf16_text: String = p_bytes.get_string_from_utf16()
			return utf16_text if not utf16_text.is_empty() else _decode_utf8(p_bytes)
		"us-ascii", "ascii":
			return p_bytes.get_string_from_ascii()
		"iso-8859-1", "iso8859-1", "latin1", "latin-1":
			# Godot 的 ASCII 解码即为 latin-1 的逐字节映射
			return p_bytes.get_string_from_ascii()
	
	# 其余编码交给系统多字节解码（Windows 用 .NET 代码页名，Linux/macOS 走 libiconv 名）
	for candidate in _multibyte_names(charset):
		var decoded: String = p_bytes.get_string_from_multibyte_char(candidate)
		if not decoded.is_empty():
			return decoded
	
	return _decode_utf8(p_bytes)


# UTF-8 优先、失败回退 latin-1
func _decode_utf8(p_bytes: PackedByteArray) -> String:
	var text: String = p_bytes.get_string_from_utf8()
	if text.is_empty() and not p_bytes.is_empty():
		text = p_bytes.get_string_from_ascii()
	
	return text.trim_prefix("\uFEFF")


# 常见编码 → 系统解码器可识别的名称候选序列
func _multibyte_names(p_charset: String) -> Array[String]:
	match p_charset:
		"gb2312", "gbk", "gb18030", "cp936", "ms936", "x-gbk":
			return ["GBK", "GB2312", "GB18030", "CP936", "936"] as Array[String]
		"big5", "big-5", "cp950":
			return ["BIG5", "BIG-5", "CP950", "950"] as Array[String]
		"shift_jis", "shift-jis", "sjis", "x-sjis", "cp932":
			return ["SHIFT_JIS", "SHIFT-JIS", "CP932", "932"] as Array[String]
		"euc-jp", "eucjp":
			return ["EUC-JP"] as Array[String]
		"euc-kr", "euckr", "cp949":
			return ["EUC-KR", "CP949", "949"] as Array[String]
		"windows-1251", "cp1251":
			return ["windows-1251", "CP1251"] as Array[String]
		"windows-1252", "cp1252":
			return ["windows-1252", "CP1252"] as Array[String]
	
	return [p_charset.to_upper()] as Array[String]


# --- Private Functions: Content Location ---

# 定位正文节点：优先用户选择器，其次语义容器，最后候选打分选优
func _locate_content(p_document: AIChatHtmlDocument, p_selector: String) -> AIChatHtmlNode:
	if not p_selector.is_empty():
		var matched: AIChatHtmlNode = p_document.query_selector(p_selector)
		if matched != null:
			return matched
	
	# 语义容器（role=main / main / article）优先级高于打分：只要文本量足够就直接采用，
	# 否则 <body> 会凭"文本量更大"胜出，把侧栏导航一起带进正文
	var preferred: AIChatHtmlNode = _find_preferred_content(p_document)
	if preferred != null:
		return preferred
	
	var best: AIChatHtmlNode = null
	var best_score: float = -1.0
	for node in p_document.walk_elements():
		if not _is_content_candidate(node):
			continue
		var score: float = _score_candidate(node)
		if score > best_score:
			best_score = score
			best = node
	
	return best


# 查找语义正文容器：按 role=main → main → article 的优先级，返回首个文本量达标的节点
# 单次遍历完成（walk_elements 只分配一次整树数组），避免三次 query_selector 各自的
# 选择器编译与整树遍历。判定语义与 query_selector("[role=main]") / ("main") / ("article") 等价。
func _find_preferred_content(p_document: AIChatHtmlDocument) -> AIChatHtmlNode:
	var candidates: Array[AIChatHtmlNode] = [null, null, null]
	
	for node in p_document.walk_elements():
		if candidates[0] == null and node.get_attribute("role") == "main":
			candidates[0] = node
		elif candidates[1] == null and node.tag_name == "main":
			candidates[1] = node
		elif candidates[2] == null and node.tag_name == "article":
			candidates[2] = node
		
		# 三类候选都已取到文档序首个节点，无需继续遍历
		if candidates[0] != null and candidates[1] != null and candidates[2] != null:
			break
	
	for candidate in candidates:
		if candidate == null:
			continue
		var stats: Dictionary = _measure_text(candidate)
		if int(stats["text_length"]) >= MIN_CANDIDATE_CHARS * 4:
			return candidate
	
	return null


# 是否为正文候选节点
func _is_content_candidate(p_node: AIChatHtmlNode) -> bool:
	if p_node.tag_name in CANDIDATE_TAGS:
		return true
	if p_node.get_attribute("role") == "main":
		return true
	
	var id_value: String = p_node.get_id().to_lower()
	if not id_value.is_empty() and _contains_candidate_keyword(id_value):
		return true
	
	var class_value: String = p_node.get_attribute("class").to_lower()
	return not class_value.is_empty() and _contains_candidate_keyword(class_value)


func _contains_candidate_keyword(p_value: String) -> bool:
	for keyword in CANDIDATE_KEYWORDS:
		if p_value.find(keyword) != -1:
			return true
	
	return false


# 候选打分：文本量 × (1 - 链接密度) + 段落数奖励
func _score_candidate(p_node: AIChatHtmlNode) -> float:
	var stats: Dictionary = _measure_text(p_node)
	var text_length: int = stats["text_length"]
	if text_length <= 0:
		return 0.0
	
	var link_density: float = float(stats["link_length"]) / float(text_length)
	var score: float = float(text_length) * (1.0 - minf(link_density, MAX_LINK_DENSITY))
	score += float(mini(stats["paragraph_count"], MAX_PARAGRAPHS_SCORED)) * PARAGRAPH_BONUS
	
	if text_length < MIN_CANDIDATE_CHARS:
		score *= 0.2
	
	return score


# 单次遍历统计：文本长度、链接文本长度、段落数
func _measure_text(p_node: AIChatHtmlNode) -> Dictionary:
	var stats: Dictionary = {"text_length": 0, "link_length": 0, "paragraph_count": 0}
	_measure_text_into(p_node, false, stats)
	return stats


func _measure_text_into(p_node: AIChatHtmlNode, p_in_link: bool, p_stats: Dictionary) -> void:
	for child in p_node.children:
		if child.is_text():
			var chars: int = child.text.strip_edges().length()
			p_stats["text_length"] = int(p_stats["text_length"]) + chars
			if p_in_link:
				p_stats["link_length"] = int(p_stats["link_length"]) + chars
		elif child.is_element():
			if child.tag_name == "p":
				p_stats["paragraph_count"] = int(p_stats["paragraph_count"]) + 1
			_measure_text_into(child, p_in_link or child.tag_name == "a", p_stats)


# --- Private Functions: Link Block Filter ---

# 剔除正文节点内"几乎全是链接"的容器块（导航 / 相关推荐 / 页脚等）
# 先做一次自底向上的文本统计，再按缓存结果单次遍历剪枝，整体 O(n)
func _prune_link_blocks(p_content_node: AIChatHtmlNode) -> void:
	var stats: Dictionary = {}
	_collect_text_stats(p_content_node, false, stats)
	
	# 正文本身就是链接列表（目录页 / 列表页）时不过滤，避免把正文清空
	if _link_density_of(stats.get(p_content_node, {})) >= MAX_CONTENT_LINK_DENSITY:
		return
	
	_prune_link_blocks_recursive(p_content_node, stats)


# 自底向上统计每个节点的 {text_length, link_length, link_count}，结果缓存在 p_stats
func _collect_text_stats(p_node: AIChatHtmlNode, p_in_link: bool, p_stats: Dictionary) -> Dictionary:
	var text_length: int = 0
	var link_length: int = 0
	var link_count: int = 0
	
	for child in p_node.children:
		if child.is_text():
			var chars: int = child.text.strip_edges().length()
			text_length += chars
			if p_in_link:
				link_length += chars
		elif child.is_element():
			var is_link: bool = child.tag_name == "a"
			if is_link and not child.get_attribute("href").is_empty():
				link_count += 1
			
			var child_stats: Dictionary = _collect_text_stats(child, p_in_link or is_link, p_stats)
			text_length += int(child_stats["text_length"])
			link_length += int(child_stats["link_length"])
			link_count += int(child_stats["link_count"])
	
	var entry: Dictionary = {
		"text_length": text_length,
		"link_length": link_length,
		"link_count": link_count,
	}
	
	p_stats[p_node] = entry
	return entry


# 链接文本占比；文本为空时返回 0
func _link_density_of(p_entry: Dictionary) -> float:
	var text_length: int = int(p_entry.get("text_length", 0))
	if text_length <= 0:
		return 0.0
	
	return float(p_entry.get("link_length", 0)) / float(text_length)


# 是否"几乎全是链接"的容器块
func _is_link_dominated(p_entry: Dictionary) -> bool:
	if int(p_entry.get("text_length", 0)) < MIN_BLOCK_CHARS:
		return false
	if int(p_entry.get("link_count", 0)) < MIN_BLOCK_LINK_COUNT:
		return false
	
	return _link_density_of(p_entry) >= MIN_BLOCK_LINK_DENSITY


# 按缓存的文本统计剪枝；命中即摘除整棵子树，不再下探
func _prune_link_blocks_recursive(p_node: AIChatHtmlNode, p_stats: Dictionary) -> void:
	var index: int = 0
	while index < p_node.children.size():
		var child: AIChatHtmlNode = p_node.children[index]
		if child.is_element():
			var entry: Dictionary = p_stats.get(child, {})
			if _is_link_dominated(entry):
				child.remove()
				continue  # 当前下标已被新元素占据，不递增
			_prune_link_blocks_recursive(child, p_stats)
		index += 1


# --- Private Functions: Text Extraction ---

# 提取 <base href>，缺失时回退文档 URL
func _find_base_url(p_document: AIChatHtmlDocument, p_fallback: String) -> String:
	for node in p_document.walk_elements():
		if node.tag_name != "base":
			continue
		var href: String = node.get_attribute("href").strip_edges()
		if not href.is_empty():
			var resolved: String = _resolve_url(p_fallback, href)
			return resolved if not resolved.is_empty() else p_fallback
	
	return p_fallback


# 提取节点下的全部文本
func _extract_text(p_node: AIChatHtmlNode, p_keep_links: bool, p_base_url: String) -> String:
	var parts: Array[String] = []
	_extract_into(p_node, p_keep_links, p_base_url, parts)
	return "\n".join(parts)


func _extract_into(p_node: AIChatHtmlNode, p_keep_links: bool, p_base_url: String, p_parts: Array[String]) -> void:
	for child in p_node.children:
		if child.is_text():
			var text: String = child.text.strip_edges()
			if not text.is_empty():
				p_parts.append(text)
			continue
		if not child.is_element():
			continue
		
		var tag: String = child.tag_name
		if tag == "tr":
			_append_table_row(child, p_keep_links, p_base_url, p_parts)
			continue
		if tag == "a" and p_keep_links:
			_append_link(child, p_keep_links, p_base_url, p_parts)
			continue
		if tag == "li":
			var item_text: String = _extract_child_text(child, p_keep_links, p_base_url)
			if not item_text.is_empty():
				p_parts.append("- " + item_text)
			continue
		if tag == "img":
			var alt: String = child.get_attribute("alt").strip_edges()
			if not alt.is_empty():
				p_parts.append("[Image: %s]" % alt)
			continue
		if tag == "td" or tag == "th":
			var cell_text: String = _extract_child_text(child, p_keep_links, p_base_url)
			if not cell_text.is_empty():
				p_parts.append(cell_text)
			continue
		
		# 块级与行内元素统一递归展开（最终由 \n 连接，结果与整段拼接一致）
		_extract_into(child, p_keep_links, p_base_url, p_parts)


func _append_link(p_node: AIChatHtmlNode, p_keep_links: bool, p_base_url: String, p_parts: Array[String]) -> void:
	var inner: String = _extract_child_text(p_node, p_keep_links, p_base_url)
	if inner.is_empty():
		return
	
	var href: String = p_node.get_attribute("href").strip_edges()
	if href.is_empty():
		p_parts.append(inner)
		return
	
	var absolute: String = _resolve_url(p_base_url, href)
	p_parts.append("%s (%s)" % [inner, absolute])


# 表格行 → markdown 风格行；含 <th> 时补一行分隔线
func _append_table_row(p_row: AIChatHtmlNode, p_keep_links: bool, p_base_url: String, p_parts: Array[String]) -> void:
	var cells: Array[String] = []
	var has_header: bool = false
	
	for cell in p_row.children:
		if not cell.is_element():
			continue
		var is_header: bool = cell.tag_name == "th"
		if not is_header and cell.tag_name != "td":
			continue
		has_header = has_header or is_header
		cells.append(_extract_child_text(cell, p_keep_links, p_base_url).replace("\n", " ").strip_edges())
	
	if cells.is_empty():
		return
	
	p_parts.append("| " + " | ".join(cells) + " |")
	if has_header:
		var separators: Array[String] = []
		for _index in cells.size():
			separators.append("---")
		
		p_parts.append("| " + " | ".join(separators) + " |")


func _extract_child_text(p_node: AIChatHtmlNode, p_keep_links: bool, p_base_url: String) -> String:
	var parts: Array[String] = []
	_extract_into(p_node, p_keep_links, p_base_url, parts)
	return "\n".join(parts)


# --- Private Functions: Text post-processing ---

# 规整空白：行内空白（含各类 Unicode 空格）合并为单空格、去行首尾空白、连续空行压缩为一行
# 正则每次调用现编译：static 缓存会导致"改了模式却仍用旧模式"，这点开销不值得换
func _shrink_whitespace(p_text: String) -> String:
	var inline_space := RegEx.new()
	inline_space.compile("[" + BLANK_CHARS + "]+")
	var line_edges := RegEx.new()
	line_edges.compile("[" + BLANK_CHARS + "]*\\n[" + BLANK_CHARS + "]*")
	var blank_lines := RegEx.new()
	blank_lines.compile("(\\n){3,}")
	
	var result: String = p_text.replace("\r\n", "\n").replace("\r", "\n")
	result = inline_space.sub(result, " ", true)
	result = line_edges.sub(result, "\n", true)
	result = blank_lines.sub(result, "\n\n", true)
	return result.strip_edges()


# 文本截断
func _truncate(p_text: String, p_max_length: int) -> String:
	if p_text.length() > p_max_length:
		return p_text.left(p_max_length) + "\n\n[...truncated at %d characters]" % p_max_length
	
	return p_text


# --- Private Functions: Utilities ---

# 响应类型分类：html / text / pdf / image
func _classify_content_type(p_content_type: String) -> String:
	var content_type: String = p_content_type.to_lower()
	if content_type.is_empty():
		return "html"
	if content_type.find("xhtml") != -1:
		return "html"
	if content_type.find("json") != -1 or content_type.find("xml") != -1 or content_type.find("text/plain") != -1:
		return "text"
	if content_type.find("pdf") != -1:
		return "pdf"
	if content_type.find("image/") != -1:
		return "image"
	
	return "html"


# 正文为空 / 过短时的失败信息：携带状态码与预览，并区分"反爬"与"JS 渲染"两类原因
func _build_short_content_error(p_url: String, p_code: int, p_content_type: String, p_title: String, p_body: String, p_text: String) -> String:
	var type_text: String = p_content_type if not p_content_type.is_empty() else "unknown"
	var summary: String = "HTTP %d for %s — no readable content extracted (%d chars, content-type: %s)." % [
		p_code, p_url, p_text.length(), type_text
	]
	
	if not p_title.is_empty():
		summary += " Page title: \"%s\"." % p_title
	
	var preview: String = p_text.strip_edges()
	if not preview.is_empty():
		summary += " Extracted preview: \"%s\"." % preview.left(PREVIEW_CHARS)
	
	if _looks_like_antibot_page(p_title, p_body):
		return "Error: %s The response looks like an anti-bot / verification page, so this site blocks automated clients. Try another source or a URL that hosts the same content." % summary
	
	return "Error: %s The page body is likely rendered by JavaScript, or the content sits behind a login or paywall. Try another source or URL." % summary


# 标题或正文开头命中反爬特征标记即判定为风控页面（仅在失败路径调用，不会误伤正常抓取）
func _looks_like_antibot_page(p_title: String, p_body: String) -> bool:
	var haystack: String = p_title.to_lower() + " " + p_body.substr(0, 4096).to_lower()
	for marker in ANTIBOT_MARKERS:
		if haystack.find(marker) != -1:
			return true
	
	return false


# 读取响应头（大小写不敏感）
func _get_header(p_headers: PackedStringArray, p_name: String) -> String:
	var prefix: String = p_name.to_lower() + ":"
	for header in p_headers:
		if header.to_lower().begins_with(prefix):
			return header.substr(prefix.length()).strip_edges()
	
	return ""


func _status_name(p_status: int) -> String:
	match p_status:
		HTTPClient.STATUS_DISCONNECTED:
			return "disconnected"
		HTTPClient.STATUS_RESOLVING:
			return "resolving host"
		HTTPClient.STATUS_CANT_RESOLVE:
			return "DNS resolution failed"
		HTTPClient.STATUS_CONNECTING:
			return "connecting"
		HTTPClient.STATUS_CANT_CONNECT:
			return "cannot connect"
		HTTPClient.STATUS_CONNECTED:
			return "connected"
		HTTPClient.STATUS_REQUESTING:
			return "requesting"
		HTTPClient.STATUS_BODY:
			return "reading body"
		HTTPClient.STATUS_CONNECTION_ERROR:
			return "connection error"
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR:
			return "TLS handshake failed"
	
	return "status %d" % p_status


# 主循环计时器等待（保持 await 可被编辑器主循环驱动）
func _sleep(p_seconds: float) -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	
	await tree.create_timer(p_seconds).timeout


# --- Private Functions: Cache ---

func _read_cache(p_url: String) -> Dictionary:
	var entry: Dictionary = _fetch_cache.get(p_url, {})
	if entry.is_empty():
		return {}
	
	var age: float = Time.get_ticks_msec() / 1000.0 - float(entry.get("time", 0.0))
	if age > CACHE_TTL_SEC:
		_fetch_cache.erase(p_url)
		return {}
	
	return entry.get("response", {})


func _write_cache(p_url: String, p_response: Dictionary) -> void:
	if int(p_response.get("code", 0)) != 200:
		return
	
	var body: String = str(p_response.get("body", ""))
	if body.is_empty() or body.length() > CACHE_ENTRY_MAX_CHARS:
		return
	
	if _fetch_cache.size() >= CACHE_MAX_ENTRIES:
		_fetch_cache.clear()
	
	_fetch_cache[p_url] = {
		"time": Time.get_ticks_msec() / 1000.0,
		"response": p_response,
	}
