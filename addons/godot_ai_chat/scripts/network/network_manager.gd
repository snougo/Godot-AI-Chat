@tool
extends Node

# 网络管理器
# 负责 Provider 配置装配、模型列表拉取，以及主对话链路的中继与生命周期管理。


# --- Signals ---

signal get_model_list_request_started
signal get_model_list_request_succeeded(model_list: Array[String])
signal get_model_list_request_failed(error: String)

# 保留流式数据信号供 UI 实时更新
signal new_chat_request_sending
signal new_stream_delta_received(delta: LLMStreamDelta)
signal new_stream_chunk_received(chunk: Dictionary)


# --- Constants ---

const StreamRequest := preload("res://addons/godot_ai_chat/scripts/network/stream_request.gd")


# --- @onready Vars ---

@onready var _http_request_node: HTTPRequest = $HTTPRequest


# --- Public Vars ---

var current_provider: BaseLLMProvider = null
var current_stream_request: StreamRequest = null

var api_key: String = ""
var api_base_url: String = ""
var temperature: float = 0.7
var current_model_name: String = ""

# 发起当前流式请求时所用的 Provider 实例
# [为什么与 current_provider 分开] current_provider 会被 get_model_list() 等操作重建，
# 而流式解析必须始终使用**发起该请求的那个实例**（其内部持有槽位映射、用量累计等流内状态）。
var streaming_provider: BaseLLMProvider = null


# --- Built-in Functions ---

func _ready() -> void:
	_http_request_node.timeout = 10.0


# --- Public Functions ---

# 设置当前模型名称
func set_model_name(p_model_name: String) -> void:
	current_model_name = p_model_name


# 从API端点获取模型列表
func get_model_list() -> void:
	if not _update_provider_config():
		get_model_list_request_failed.emit("Invalid Provider Configuration")
		return
	
	if api_base_url.is_empty():
		get_model_list_request_failed.emit("Please Configure Plugin Settings!")
		return
	
	get_model_list_request_started.emit()
	
	if not current_provider.supports_model_list_api(api_base_url):
		var static_models: Array[String] = current_provider.get_static_model_list()
		get_model_list_request_succeeded.emit(static_models)
		return
	
	var url: String = current_provider.get_request_url(api_base_url, "", api_key, false)
	var headers: PackedStringArray = current_provider.get_request_headers(api_key, false)
	
	if _http_request_node.request_completed.is_connected(_on_model_list_completed):
		_http_request_node.request_completed.disconnect(_on_model_list_completed)
	_http_request_node.request_completed.connect(_on_model_list_completed, CONNECT_ONE_SHOT)
	
	var err: Error = _http_request_node.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		get_model_list_request_failed.emit("Request failed: %s" % error_string(err))


# 异步网络请求
func request_chat_async(p_messages: Array[ChatMessage]) -> Dictionary:
	if current_stream_request != null:
		cancel_stream()
		await get_tree().process_frame
	
	if current_model_name.is_empty():
		return {"success": false, "error": "No model selected."}
	
	if not _update_provider_config():
		return {"success": false, "error": "Configuration Error"}
	
	# 以能力查询替代 Provider 类型特判：工具 schema 方言由 Provider 自行声明
	var requires_gemini_schema: bool = current_provider.requires_gemini_tool_schema()
	var tools: Array = ToolRegistry.get_all_tool_definitions(requires_gemini_schema)
	
	var body: Dictionary = current_provider.build_request_body(current_model_name, p_messages, temperature, true, tools)
	var url: String = current_provider.get_request_url(api_base_url, current_model_name, api_key, true)
	var headers: PackedStringArray = current_provider.get_request_headers(api_key, true)
	
	var settings: PluginSettingsConfig = ToolBox.get_plugin_settings()
	streaming_provider = current_provider
	
	# 发起新请求前重置 Provider 的流内状态（槽位映射、用量累计等）
	current_provider.reset_stream_state()
	
	current_stream_request = StreamRequest.new(
		current_provider,
		url,
		headers,
		body,
		TimeoutTracker.from_network_timeout(settings.network_timeout)
	)
	var local_request_ref: StreamRequest = current_stream_request
	
	local_request_ref.delta_received.connect(_relay_stream_delta)
	local_request_ref.chunk_received.connect(_relay_stream_chunk)
	
	new_chat_request_sending.emit()
	local_request_ref.start()
	
	# 主线程每帧驱动超时看门狗，直到请求进入唯一终态（完成 / 失败 / 超时 / 被取消）
	while not local_request_ref.is_settled():
		local_request_ref.poll_watchdog()
		if local_request_ref.is_settled():
			break
		await get_tree().process_frame
	
	var error_msg: String = local_request_ref.get_error_message()
	var result: Dictionary = {
		"success": not local_request_ref.is_cancelled() and error_msg.is_empty(),
		"error": error_msg
	}
	
	# 请求线程池任务回收（非阻塞），清理内部资源
	local_request_ref.request_thread_cleanup()
	
	if current_stream_request == local_request_ref:
		_clear_current_stream_request()
	return result


# 非流式异步请求（用于上下文压缩等场景）
func request_non_stream_async(p_messages: Array[ChatMessage], p_config: ContextCompressionConfig) -> Dictionary:
	if p_config == null:
		return {"success": false, "error": "Compression config is missing.", "error_kind": "config"}
	
	var config_error: String = p_config.validate()
	if not config_error.is_empty():
		return {"success": false, "error": config_error, "error_kind": "config"}
	
	var provider: BaseLLMProvider = ProviderFactory.create_provider(p_config.api_provider)
	if provider == null:
		return {"success": false, "error": "Invalid provider for summarization.", "error_kind": "config"}
	
	provider.set_active_model_name(p_config.model_name)
	provider.set_active_base_url(p_config.api_base_url)
	
	var base_url: String = p_config.api_base_url
	var key: String = p_config.api_key
	var temp: float = p_config.temperature
	var model_name: String = p_config.model_name
	
	# 构建非流式请求
	var body_dict: Dictionary = provider.build_request_body(model_name, p_messages, temp, false, [])
	var body_json: String = ToolBox.stringify_json_safe(body_dict)
	var url: String = provider.get_request_url(base_url, model_name, key, false)
	var headers: PackedStringArray = provider.get_request_headers(key, false)
	
	# 创建专用 HTTPRequest 节点（避免与模型列表请求冲突）
	var http_req: HTTPRequest = HTTPRequest.new()
	add_child(http_req)
	
	var settings: PluginSettingsConfig = ToolBox.get_plugin_settings()
	http_req.timeout = float(settings.network_timeout)
	
	var state: Dictionary = {"is_done": false}
	var result: Dictionary = {"success": false, "error": "", "error_kind": "runtime", "content": ""}
	
	var on_completed := func(p_res: int, p_code: int, _p_headers: PackedStringArray, p_body: PackedByteArray):
		state.is_done = true
		
		if p_res != HTTPRequest.RESULT_SUCCESS:
			result.error_kind = "runtime"
			result.error = "Request failed (result: %d)" % p_res
			return
		
		if p_code != 200:
			result.error_kind = "config" if (p_code >= 400 and p_code < 500) else "runtime"
			var err_detail: String = ""
			if not p_body.is_empty():
				err_detail = p_body.get_string_from_utf8().substr(0, 500)
			result.error = "HTTP Error (code: %d)" % p_code
			if not err_detail.is_empty():
				result.error += "\n" + err_detail
			return
		
		var parsed: Dictionary = provider.parse_non_stream_response(p_body)
		if parsed.has("error"):
			result.error_kind = "config"
			result.error = "API Error: " + str(parsed.get("error", "Unknown"))
		else:
			result.success = true
			result.content = parsed.get("content", "")
	
	http_req.request_completed.connect(on_completed, CONNECT_ONE_SHOT)
	
	var err: Error = http_req.request(url, headers, HTTPClient.METHOD_POST, body_json)
	if err != OK:
		http_req.queue_free()
		return {"success": false, "error": "Request failed: %s" % error_string(err), "error_kind": "config"}
	
	while not state.is_done:
		await get_tree().process_frame
	
	http_req.queue_free()
	return result


# 取消当前流式请求
# 非阻塞：立即锁定 StreamRequest 的取消终态，置位停止标志后交由后台线程自行收尾。
func cancel_stream() -> void:
	if current_stream_request:
		current_stream_request.cancel()
		current_stream_request.request_thread_cleanup()
		_clear_current_stream_request()


# --- Private Functions ---

func _update_provider_config() -> bool:
	var settings: PluginSettingsConfig = ToolBox.get_plugin_settings()
	api_key = settings.api_key
	api_base_url = settings.api_base_url
	temperature = settings.temperature
	
	current_provider = ProviderFactory.create_provider(settings.api_provider)
	if current_provider != null:
		current_provider.set_active_model_name(current_model_name)
		current_provider.set_active_base_url(api_base_url)
	return current_provider != null


func _clear_current_stream_request() -> void:
	if current_stream_request:
		if current_stream_request.delta_received.is_connected(_relay_stream_delta):
			current_stream_request.delta_received.disconnect(_relay_stream_delta)
		if current_stream_request.chunk_received.is_connected(_relay_stream_chunk):
			current_stream_request.chunk_received.disconnect(_relay_stream_chunk)
		current_stream_request = null
	
	streaming_provider = null


func _on_model_list_completed(p_result: int, p_response_code: int, _p_headers: PackedStringArray, p_body: PackedByteArray) -> void:
	if p_result != HTTPRequest.RESULT_SUCCESS or p_response_code != 200:
		get_model_list_request_failed.emit("HTTP Error %d" % p_response_code)
		return
	
	var list: Array[String] = current_provider.parse_model_list_response(p_body)
	if not list.is_empty():
		list.sort()
		get_model_list_request_succeeded.emit(list)
	else:
		get_model_list_request_failed.emit("No models found or invalid response format")


# 中继 StreamRequest 已解析好的 LLMStreamDelta 到 UI 信号
func _relay_stream_delta(p_delta: LLMStreamDelta) -> void:
	new_stream_delta_received.emit(p_delta)


# 中继 StreamRequest 的原始流式数据块（兼容保留）
func _relay_stream_chunk(p_chunk: Dictionary) -> void:
	new_stream_chunk_received.emit(p_chunk)
