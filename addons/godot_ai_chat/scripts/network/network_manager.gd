@tool
class_name NetworkManager
extends Node

signal get_model_list_request_started
signal get_model_list_request_succeeded(model_list: Array[String])
signal get_model_list_request_failed(error: String)

# 保留流式数据信号供 UI 实时更新
signal new_chat_request_sending
signal new_stream_chunk_received(chunk: Dictionary)
signal chat_usage_data_received(usage: Dictionary)

@onready var _http_request_node: HTTPRequest = $HTTPRequest

var current_provider: BaseLLMProvider = null
var current_stream_request: StreamRequest = null

var api_key: String = ""
var api_base_url: String = ""
var temperature: float = 0.7
var current_model_name: String = ""


func _ready() -> void:
	_http_request_node.timeout = 10.0


## 从API端点获取模型列表
func get_model_list() -> void:
	if not _update_provider_config():
		get_model_list_request_failed.emit("Invalid Provider Configuration")
		return
	if api_base_url.is_empty():
		get_model_list_request_failed.emit("Please Configure Plugin Settings!")
		return
	
	get_model_list_request_started.emit()
	
	if not current_provider.supports_model_list_api(api_base_url):
		var models: Array[String] = current_provider.get_static_model_list()
		get_model_list_request_succeeded.emit(models)
		return
	
	var url: String = current_provider.get_request_url(api_base_url, "", api_key, false)
	var headers: PackedStringArray = current_provider.get_request_headers(api_key, false)
	
	if _http_request_node.request_completed.is_connected(_on_model_list_completed):
		_http_request_node.request_completed.disconnect(_on_model_list_completed)
	_http_request_node.request_completed.connect(_on_model_list_completed, CONNECT_ONE_SHOT)
	
	var err: Error = _http_request_node.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		get_model_list_request_failed.emit("Request failed: %s" % error_string(err))


## 异步网络请求
func request_chat_async(p_messages: Array[ChatMessage]) -> Dictionary:
	if current_stream_request != null:
		cancel_stream()
		await get_tree().process_frame
	
	if current_model_name.is_empty():
		return {"success": false, "error": "No model selected."}
	
	if not _update_provider_config():
		return {"success": false, "error": "Configuration Error"}
	
	var is_gemini: bool = (current_provider is GeminiProvider)
	var tools: Array = ToolRegistry.get_all_tool_definitions(is_gemini)
	var body: Dictionary = current_provider.build_request_body(current_model_name, p_messages, temperature, true, tools)
	var url: String = current_provider.get_request_url(api_base_url, current_model_name, api_key, true)
	var headers: PackedStringArray = current_provider.get_request_headers(api_key, true)
	
	var settings: PluginSettingsConfig = ToolBox.get_plugin_settings()
	current_stream_request = StreamRequest.new(current_provider, url, headers, body, TimeoutTracker.from_network_timeout(settings.network_timeout))
	var _local_request_ref: StreamRequest = current_stream_request
	
	var result := {"success": false, "error": ""}
	var state := {"is_finished": false}
	
	current_stream_request.chunk_received.connect(_relay_stream_chunk)
	current_stream_request.usage_received.connect(_relay_stream_usage)
	
	current_stream_request.failed.connect(func(err_msg: String): 
		result.error = err_msg
		state.is_finished = true
		_clear_current_stream_request()
	, CONNECT_ONE_SHOT)
	
	current_stream_request.finished.connect(func(): 
		result.success = true
		state.is_finished = true
		_clear_current_stream_request()
	, CONNECT_ONE_SHOT)
	
	new_chat_request_sending.emit()
	current_stream_request.start()
	
	# 阻塞协程直到流式接收结束
	while not state.is_finished and current_stream_request != null:
		await get_tree().process_frame
	
	if not state.is_finished and result.error.is_empty():
		result.success = false
		result.error = "Cancelled by User"
	
	# [Fix] 等待 WorkerThreadPool 任务完成，清理内部资源
	if _local_request_ref != null:
		_local_request_ref.wait_for_cleanup()
	
	_clear_current_stream_request()
	return result


## 非流式异步请求（用于上下文压缩等场景）
## [param p_messages]: 消息列表
## [param p_config]: 压缩配置（为 null 时使用主对话配置）
## [return]: {"success": bool, "error": String, "content": String}
func request_non_stream_async(p_messages: Array[ChatMessage], p_config: ContextCompressionConfig = null) -> Dictionary:
	var provider: BaseLLMProvider
	var base_url: String
	var key: String
	var temp: float
	var model_name: String
	
	# 解析配置：优先使用独立压缩配置，否则回退到主对话配置
	if p_config and p_config.enabled and not p_config.api_base_url.is_empty():
		provider = ProviderFactory.create_provider(p_config.api_provider)
		base_url = p_config.api_base_url
		key = p_config.api_key
		temp = p_config.temperature
		model_name = p_config.model_name
	else:
		if not _update_provider_config():
			return {"success": false, "error": "Configuration Error"}
		provider = current_provider
		base_url = api_base_url
		key = api_key
		temp = temperature
		model_name = current_model_name
	
	if model_name.is_empty():
		return {"success": false, "error": "No model selected for summarization."}
	if not provider:
		return {"success": false, "error": "Invalid provider for summarization."}
	
	# 构建非流式请求
	var body_dict: Dictionary = provider.build_request_body(model_name, p_messages, temp, false, [])
	var body_json: String = JSON.stringify(body_dict)
	var url: String = provider.get_request_url(base_url, model_name, key, false)
	var headers: PackedStringArray = provider.get_request_headers(key, false)
	
	# 创建专用 HTTPRequest 节点（避免与模型列表请求冲突）
	var http_req := HTTPRequest.new()
	add_child(http_req)
	
	var settings := ToolBox.get_plugin_settings()
	http_req.timeout = float(settings.network_timeout)
	
	var state := {"is_done": false}
	var result := {"success": false, "error": "", "content": ""}
	
	var on_completed := func(p_res: int, p_code: int, _p_headers: PackedStringArray, p_body: PackedByteArray):
		state.is_done = true
		if p_res != HTTPRequest.RESULT_SUCCESS or p_code != 200:
			var err_detail: String = ""
			if not p_body.is_empty():
				err_detail = p_body.get_string_from_utf8().substr(0, 500)
			result.error = "HTTP Error (code: %d, result: %d)" % [p_code, p_res]
			if not err_detail.is_empty():
				result.error += "\n" + err_detail
			return
		
		var parsed: Dictionary = provider.parse_non_stream_response(p_body)
		if parsed.has("error"):
			result.error = "API Error: " + str(parsed.get("error", "Unknown"))
		else:
			result.success = true
			result.content = parsed.get("content", "")
	
	http_req.request_completed.connect(on_completed, CONNECT_ONE_SHOT)
	
	var err := http_req.request(url, headers, HTTPClient.METHOD_POST, body_json)
	if err != OK:
		http_req.queue_free()
		return {"success": false, "error": "Request failed: %s" % error_string(err)}
	
	while not state.is_done:
		await get_tree().process_frame
	
	http_req.queue_free()
	return result


func cancel_stream() -> void:
	if current_stream_request:
		current_stream_request.cancel()
		_clear_current_stream_request()


func _update_provider_config() -> bool:
	var settings: PluginSettingsConfig = ToolBox.get_plugin_settings()
	api_key = settings.api_key
	api_base_url = settings.api_base_url
	temperature = settings.temperature
	
	current_provider = ProviderFactory.create_provider(settings.api_provider)
	return current_provider != null


func _clear_current_stream_request() -> void:
	if current_stream_request:
		if current_stream_request.chunk_received.is_connected(_relay_stream_chunk):
			current_stream_request.chunk_received.disconnect(_relay_stream_chunk)
		if current_stream_request.usage_received.is_connected(_relay_stream_usage):
			current_stream_request.usage_received.disconnect(_relay_stream_usage)
		current_stream_request = null


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


# 中继 StreamRequest 的流式数据块到 UI 信号
func _relay_stream_chunk(p_chunk: Dictionary) -> void:
	new_stream_chunk_received.emit(p_chunk)


# 中继 StreamRequest 的用量数据到 UI 信号
func _relay_stream_usage(p_usage: Dictionary) -> void:
	chat_usage_data_received.emit(p_usage)
