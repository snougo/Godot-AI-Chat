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
	
	if current_provider is ZhipuAIProvider:
		var model_list: Array[String] = current_provider.parse_model_list_response(PackedByteArray())
		get_model_list_request_succeeded.emit(model_list)
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
	
	current_stream_request = StreamRequest.new(current_provider, url, headers, body)
	
	var result := {"success": false, "error": ""}
	var state := {"is_finished": false}
	
	# [Fix] 移除冗余的超时检测逻辑，由 StreamRequest 统一处理
	current_stream_request.chunk_received.connect(func(chunk: Dictionary): 
		new_stream_chunk_received.emit(chunk)
	)
	
	current_stream_request.usage_received.connect(func(usage: Dictionary): 
		chat_usage_data_received.emit(usage)
	)
	
	current_stream_request.failed.connect(func(err_msg: String): 
		result.error = err_msg
		state.is_finished = true
	)
	
	current_stream_request.finished.connect(func(): 
		result.success = true
		state.is_finished = true
	)
	
	new_chat_request_sending.emit()
	current_stream_request.start()
	
	# 阻塞协程直到流式接收结束
	while not state.is_finished and current_stream_request != null:
		await get_tree().process_frame
	
	if not state.is_finished and result.error.is_empty():
		result.success = false
		result.error = "Cancelled by User"
	
	_clear_current_stream_request()
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
