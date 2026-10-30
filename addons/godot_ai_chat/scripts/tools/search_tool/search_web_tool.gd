extends AiTool

## 执行在线搜索（Tavily Search API）。
##
## 使用 HTTPClient 实现，无需节点挂载，无场景依赖。
## 具备分阶段超时、响应体大小上限、有限重试与短期结果缓存。


# --- Constants ---

const SEARCH_HOST: String = "api.tavily.com"
const SEARCH_PORT: int = 443
const SEARCH_PATH: String = "/search"

## 分阶段超时（秒）：避免单一超时被某一阶段耗尽
const CONNECT_TIMEOUT: float = 10.0
const HEADER_TIMEOUT: float = 20.0
const BODY_TIMEOUT: float = 20.0

const MAX_RETRIES: int = 1
const RETRY_BASE_DELAY: float = 0.4

## 响应体大小上限（字节）
const MAX_RESPONSE_BYTES: int = 2 * 1024 * 1024

## 错误详情与单条结果摘要的最大字符数
const MAX_ERROR_DETAIL_CHARS: int = 500
const MAX_RESULT_CONTENT_CHARS: int = 600

## 错误响应体中优先取用的消息键（按优先级）
const ERROR_MESSAGE_KEYS: Array[String] = ["detail", "error", "message", "msg"]

## 错误消息中最多聚合的数组项数（Tavily 422 会返回多条校验错误）
const MAX_ERROR_ITEMS: int = 3

const DEFAULT_MAX_RESULTS: int = 6
const MAX_RESULTS_LIMIT: int = 20

## 搜索深度白名单与默认值
## basic = 1 credit/次，advanced = 2 credits/次（更深的抓取与更强的结果召回）
## 默认取 basic 以节省额度：免费账户 1000 credits/月 ≈ 1000 次 basic 或 500 次 advanced
const SEARCH_DEPTHS: Array[String] = ["basic", "advanced"]
const DEFAULT_SEARCH_DEPTH: String = "basic"

## 相同查询的结果缓存时长（秒）与条目上限
## 注意：Tavily 的 advanced 深度单次消耗 2 credits，缓存可显著省额度
const CACHE_TTL_SEC: float = 300.0
const CACHE_MAX_ENTRIES: int = 8


# --- Private Vars ---

## 搜索结果缓存：{ "max_results|query": {"time": float, "data": String} }
static var _search_cache: Dictionary = {}


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "search_web"
	tool_description = "Performs an online search and returns a direct answer."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"query": {
				"type": "string",
				"description": "The search query to find information about."
			},
			"search_depth": {
				"type": "string",
				"enum": SEARCH_DEPTHS,
				"description": "Search depth. 'basic' (default) costs 1 API credit and handles most queries well. 'advanced' costs 2 credits but digs deeper and returns richer snippets — use it for research-style or ambiguous queries.",
				"default": DEFAULT_SEARCH_DEPTH
			},
			"max_results": {
				"type": "integer",
				"description": "Maximum number of results to return (1-20). Default: 6.",
				"default": DEFAULT_MAX_RESULTS
			}
		},
		"required": ["query"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var query: String = str(p_args.get("query", "")).strip_edges()
	if query.is_empty():
		return ToolResult.fail("Error: Query cannot be empty.")
	
	var settings: PluginSettingsConfig = ToolBox.get_plugin_settings()
	var api_key: String = settings.tavily_api_key.strip_edges()
	if api_key.is_empty():
		return ToolResult.fail("Error: Tavily API Key is not configured. Please set it in the plugin settings.")
	
	var max_results: int = _parse_max_results(p_args)
	var search_depth: String = _parse_search_depth(p_args)
	
	var cache_key: String = "%s|%d|%s" % [search_depth, max_results, query.to_lower()]
	var cached: String = _read_cache(cache_key)
	if not cached.is_empty():
		return ToolResult.ok(cached)
	
	var result: ToolResult = await _request_search(query, api_key, max_results, search_depth)
	if result.is_ok():
		_write_cache(cache_key, result.get_data())
	
	return result


# --- Private Functions: Request ---

# 发起搜索请求（失败时按 retryable 有限重试）
func _request_search(p_query: String, p_api_key: String, p_max_results: int, p_search_depth: String) -> ToolResult:
	var body: String = ToolBox.stringify_json_safe({
		"api_key": p_api_key,
		"query": p_query,
		# basic = 1 credit/次，advanced = 2 credits/次
		"search_depth": p_search_depth,
		"include_answer": true,
		"max_results": p_max_results
	})
	
	var last_error: String = "Unknown network error."
	for attempt: int in range(MAX_RETRIES + 1):
		var response: Dictionary = await _http_post_json(body)
		if response.get("success", false):
			return _parse_response(str(response.get("body", "")))
		
		last_error = str(response.get("error", "Unknown network error."))
		if not response.get("retryable", false) or attempt >= MAX_RETRIES:
			break
		
		await _sleep(RETRY_BASE_DELAY * float(attempt + 1))
	
	return ToolResult.fail("Error: %s" % last_error)


# 单次 HTTPS POST（JSON）
# [return]: {success: true, body: String} 或 {success: false, error: String, retryable: bool}
func _http_post_json(p_body: String) -> Dictionary:
	var client := HTTPClient.new()
	
	var err: Error = client.connect_to_host(SEARCH_HOST, SEARCH_PORT, TLSOptions.client())
	if err != OK:
		client.close()
		return {"success": false, "error": "Connection init failed (%s)." % error_string(err), "retryable": true}
	
	# 阶段 1：DNS + TCP + TLS
	if not await _poll_while_status_in(client, [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING], CONNECT_TIMEOUT):
		client.close()
		return {"success": false, "error": "Connection timeout.", "retryable": true}
	
	var status: int = client.get_status()
	if status != HTTPClient.STATUS_CONNECTED:
		client.close()
		return {"success": false, "error": "Connection failed (%s)." % _status_name(status), "retryable": true}
	
	# 阶段 2：发送请求并等待响应头
	var headers: PackedStringArray = ["Content-Type: application/json", "Accept: application/json"]
	err = client.request(HTTPClient.METHOD_POST, SEARCH_PATH, headers, p_body)
	if err != OK:
		client.close()
		return {"success": false, "error": "Request failed (%s)." % error_string(err), "retryable": true}
	
	if not await _poll_while_status_in(client, [HTTPClient.STATUS_REQUESTING], HEADER_TIMEOUT):
		client.close()
		return {"success": false, "error": "Request timeout.", "retryable": true}
	
	var code: int = client.get_response_code()
	
	# 阶段 3：读取响应体（错误响应同样要读，用于提取服务端错误详情）
	var read_result: Dictionary = await _read_body(client)
	client.close()
	
	if not read_result.get("success", false):
		return {"success": false, "error": str(read_result.get("error", "Response body read failed.")), "retryable": true}
	
	var response_body: String = str(read_result.get("body", ""))
	
	if code != 200:
		var detail: String = _extract_error_detail(response_body)
		var message: String = "HTTP %d" % code
		if not detail.is_empty():
			message += " - " + detail
		return {"success": false, "error": message, "retryable": code >= 500 or code == 429}
	
	return {"success": true, "body": response_body}


# 轮询直至状态离开 p_wait_states；返回 true 表示正常退出，false 表示超时
func _poll_while_status_in(p_client: HTTPClient, p_wait_states: Array, p_timeout: float) -> bool:
	var deadline: int = Time.get_ticks_msec() + int(p_timeout * 1000.0)
	
	while p_client.get_status() in p_wait_states:
		p_client.poll()
		if not p_client.get_status() in p_wait_states:
			return true
		
		await _wait_frame()
		if Time.get_ticks_msec() >= deadline:
			return false
	
	return true


# 读取响应体：带大小上限与超时，并在连接异常中断时明确报因
func _read_body(p_client: HTTPClient) -> Dictionary:
	var body := PackedByteArray()
	var deadline: int = Time.get_ticks_msec() + int(BODY_TIMEOUT * 1000.0)
	
	while p_client.get_status() == HTTPClient.STATUS_BODY:
		p_client.poll()
		var chunk: PackedByteArray = p_client.read_response_body_chunk()
		if not chunk.is_empty():
			if body.size() + chunk.size() > MAX_RESPONSE_BYTES:
				return {"success": false, "error": "Response body exceeds the %d bytes limit." % MAX_RESPONSE_BYTES}
			body.append_array(chunk)
		
		if p_client.get_status() == HTTPClient.STATUS_BODY:
			await _wait_frame()
			if Time.get_ticks_msec() >= deadline:
				return {"success": false, "error": "Response body read timeout."}
	
	# 连接被中途掐断时状态会变为 CONNECTION_ERROR 等，这里显式报因，
	# 否则截断的 body 会以 "Invalid JSON response" 的形式误导排查
	var status: int = p_client.get_status()
	if status != HTTPClient.STATUS_CONNECTED and status != HTTPClient.STATUS_DISCONNECTED:
		return {"success": false, "error": "Connection lost while receiving the response (%s)." % _status_name(status)}
	
	return {"success": true, "body": body.get_string_from_utf8()}


# --- Private Functions: Parsing ---

# 解析 Tavily 响应：提取 answer 与 results，输出为 Markdown 文本
func _parse_response(p_json_text: String) -> ToolResult:
	var parsed: Variant = JSON.parse_string(p_json_text)
	if not parsed is Dictionary:
		return ToolResult.fail("Error: Invalid JSON response from the search API.")
	
	var json: Dictionary = parsed
	if json.has("error"):
		return ToolResult.fail("Error: %s" % str(json.get("error", "Unknown API error.")))
	
	var sections: Array[String] = []
	
	var answer: String = str(json.get("answer", "")).strip_edges()
	if not answer.is_empty():
		sections.append("Direct Answer: " + answer)
	
	var lines: Array[String] = []
	var results: Array = json.get("results", [])
	
	for item: Variant in results:
		if not item is Dictionary:
			continue
		
		var entry: Dictionary = item
		var url: String = str(entry.get("url", "")).strip_edges()
		var title: String = str(entry.get("title", "")).strip_edges()
		if title.is_empty():
			title = url if not url.is_empty() else "Untitled"
		if url.is_empty():
			url = "#"
		
		var content: String = _truncate(str(entry.get("content", "")).strip_edges(), MAX_RESULT_CONTENT_CHARS)
		lines.append("%d. [%s](%s)\n%s" % [lines.size() + 1, title, url, content])
	
	if not lines.is_empty():
		sections.append("Search Results:\n" + "\n".join(lines))
	
	# 空结果不能算成功：空字符串会让模型误以为"搜到了但内容为空"
	if sections.is_empty():
		return ToolResult.fail("Error: No search results found for this query. Try rephrasing it or searching for more specific terms.")
	
	return ToolResult.ok("\n\n".join(sections))


# --- Private Functions: Utilities ---

# 解析 max_results 参数：缺省/非法值回退默认，并夹取到 [1, 20]
func _parse_max_results(p_args: Dictionary) -> int:
	var raw_value: Variant = p_args.get("max_results", null)
	if raw_value == null:
		return DEFAULT_MAX_RESULTS
	
	var value: int = int(str(raw_value))
	if value <= 0:
		return DEFAULT_MAX_RESULTS
	
	return clampi(value, 1, MAX_RESULTS_LIMIT)


# 解析 search_depth 参数：仅接受白名单内的值，非法/缺省回退默认
func _parse_search_depth(p_args: Dictionary) -> String:
	var value: String = str(p_args.get("search_depth", "")).strip_edges().to_lower()
	if value in SEARCH_DEPTHS:
		return value
	
	return DEFAULT_SEARCH_DEPTH


# 从错误响应体中提取可读详情（Tavily 失败时返回 {"detail": ...} / {"error": ...}）
# 注意：detail 自身可能是嵌套字典（如 {"detail": {"error": "..."}}）
# 或数组（422 校验错误），直接 str() 会带出花括号噪声，这里逐层下钻取出真正的消息文本
func _extract_error_detail(p_body: String) -> String:
	var trimmed: String = p_body.strip_edges()
	if trimmed.is_empty():
		return ""
	
	var parsed: Variant = JSON.parse_string(trimmed)
	if not parsed is Dictionary:
		return _truncate(trimmed, MAX_ERROR_DETAIL_CHARS)
	
	var message: String = _find_error_message(parsed)
	if message.is_empty():
		return ""
	
	return _truncate(message, MAX_ERROR_DETAIL_CHARS)


# 在错误对象中逐层下钻，取出真正的消息文本（跳过嵌套结构的花括号噪声）
func _find_error_message(p_value: Variant) -> String:
	if p_value == null:
		return ""
	
	if p_value is String or p_value is StringName:
		return str(p_value).strip_edges()
	
	if p_value is Array or p_value is PackedStringArray:
		var parts: PackedStringArray = PackedStringArray()
		for item: Variant in p_value:
			if parts.size() >= MAX_ERROR_ITEMS:
				break
			var nested: String = _find_error_message(item)
			if not nested.is_empty():
				parts.append(nested)
		return "; ".join(parts)
	
	if p_value is Dictionary:
		var dict: Dictionary = p_value
		for key: String in ERROR_MESSAGE_KEYS:
			if dict.has(key):
				var nested: String = _find_error_message(dict[key])
				if not nested.is_empty():
					return nested
		# 无已知消息键 → 退化为整体序列化，至少保留信息
		return JSON.stringify(dict)
	
	return str(p_value)


# 文本截断
func _truncate(p_text: String, p_max_length: int) -> String:
	if p_text.length() > p_max_length:
		return p_text.left(p_max_length) + "..."
	return p_text


# 状态枚举 → 可读名称
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


# 等待一帧（比每次轮询新建 SceneTreeTimer 更轻，且不受轮询间隔常量约束）
func _wait_frame() -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	
	await tree.process_frame


# 延时等待（用于重试退避）
func _sleep(p_seconds: float) -> void:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	
	await tree.create_timer(p_seconds).timeout


# --- Private Functions: Cache ---

# 读取未过期的缓存结果；未命中或已过期返回空字符串
func _read_cache(p_key: String) -> String:
	var entry: Dictionary = _search_cache.get(p_key, {})
	if entry.is_empty():
		return ""
	
	if Time.get_ticks_msec() / 1000.0 - float(entry.get("time", 0.0)) > CACHE_TTL_SEC:
		_search_cache.erase(p_key)
		return ""
	
	return str(entry.get("data", ""))


# 写入缓存（仅成功结果）
func _write_cache(p_key: String, p_data: String) -> void:
	if p_data.is_empty():
		return
	
	if _search_cache.size() >= CACHE_MAX_ENTRIES:
		_search_cache.clear()
	
	_search_cache[p_key] = {
		"time": Time.get_ticks_msec() / 1000.0,
		"data": p_data,
	}
