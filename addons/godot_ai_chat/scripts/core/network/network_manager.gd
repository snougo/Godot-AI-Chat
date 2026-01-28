@tool
class_name NetworkManager
extends Node

## 网络管理器
##
## 负责管理网络请求、Provider 初始化以及流式请求的生命周期。

# --- Signals ---

signal get_model_list_request_started
signal get_model_list_request_succeeded(model_list: Array[String])
signal get_model_list_request_failed(error: String)

# 流式相关信号
signal new_chat_request_sending
signal new_stream_chunk_received(chunk: Dictionary)
signal chat_stream_request_completed
signal chat_stream_request_canceled
signal chat_request_failed(error: String)
signal chat_usage_data_received(usage: Dictionary)

# --- @onready Vars ---

@onready var _http_request_node: HTTPRequest = $HTTPRequest

# --- Public Vars ---

## 当前使用的 Provider 实例
var current_provider: BaseLLMProvider = null
## 当前正在运行的流式请求
var current_stream_request: StreamRequest = null

## 缓存的 API 配置
var api_key: String = ""
var api_base_url: String = ""
var temperature: float = 0.7
var current_model_name: String = ""


# --- Built-in Functions ---

func _ready() -> void:
	_http_request_node.timeout = 10.0


# --- Public Functions ---

## 获取模型列表
func get_model_list() -> void:
	if not _update_provider_config():
		get_model_list_request_failed.emit("Invalid Provider Configuration")
		return
	
	# 检查 Base URL 是否为空
	if api_base_url.is_empty():
		get_model_list_request_failed.emit("Please Configure Plugin Settings!")
		return
	
	get_model_list_request_started.emit()
	
	# 特殊处理 ZhipuAI - 直接返回硬编码模型列表
	if current_provider is ZhipuAIProvider:
		var model_list: Array[String] = current_provider.parse_model_list_response(PackedByteArray())
		get_model_list_request_succeeded.emit(model_list)
		return
	
	# 其他提供商的正常处理逻辑
	var url: String = current_provider.get_request_url(api_base_url, "", api_key, false)
	
	# OpenAI 兼容接口特例修正 - 获取模型列表需要特殊URL
	if current_provider is BaseOpenAIProvider:
		url = api_base_url.path_join("v1/models")
	
	var headers: PackedStringArray = current_provider.get_request_headers(api_key, false)
	
	if _http_request_node.request_completed.is_connected(_on_model_list_completed):
		_http_request_node.request_completed.disconnect(_on_model_list_completed)
	
	_http_request_node.request_completed.connect(_on_model_list_completed, CONNECT_ONE_SHOT)
	var err: Error = _http_request_node.request(url, headers, HTTPClient.METHOD_GET)
	
	if err != OK:
		get_model_list_request_failed.emit("Request failed: %s" % error_string(err))


## 发起聊天流
func start_chat_stream(p_messages: Array[ChatMessage]) -> void:
	if current_model_name.is_empty():
		chat_request_failed.emit("No model selected.")
		return
	
	if not _update_provider_config():
		chat_request_failed.emit("Configuration Error")
		return
	
	var is_gemini: bool = (current_provider is GeminiProvider)
	var tools: Array = ToolRegistry.get_all_tool_definitions(is_gemini)
	
	var body: Dictionary = current_provider.build_request_body(current_model_name, p_messages, temperature, true, tools)
	var url: String = current_provider.get_request_url(api_base_url, current_model_name, api_key, true)
	var headers: PackedStringArray = current_provider.get_request_headers(api_key, true)
	
	current_stream_request = StreamRequest.new(current_provider, url, headers, body)
	
	current_stream_request.chunk_received.connect(func(chunk: Dictionary): new_stream_chunk_received.emit(chunk))
	current_stream_request.usage_received.connect(func(usage: Dictionary): chat_usage_data_received.emit(usage))
	current_stream_request.failed.connect(func(err_msg: String): chat_request_failed.emit(err_msg))
	current_stream_request.finished.connect(func(): chat_stream_request_completed.emit())
	
	new_chat_request_sending.emit()
	current_stream_request.start()


## 停止流
func cancel_stream() -> void:
	if current_stream_request:
		current_stream_request.cancel()
		chat_stream_request_canceled.emit()


# --- Private Functions ---

## 初始化 Provider 配置
func _update_provider_config() -> bool:
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	api_key = settings.api_key
	api_base_url = settings.api_base_url
	temperature = settings.temperature
	
	# 使用工厂创建实例
	current_provider = ProviderFactory.create_provider(settings.api_provider)
	if current_provider == null:
		return false
	
	return true


# --- Signal Callbacks ---

func _on_model_list_completed(p_result: int, p_response_code: int, _p_headers: PackedStringArray, p_body: PackedByteArray) -> void:
	if p_result != HTTPRequest.RESULT_SUCCESS or p_response_code != 200:
		get_model_list_request_failed.emit("HTTP Error %d" % p_response_code)
		return
	
	# 使用 Provider 进行多态解析
	var list: Array[String] = current_provider.parse_model_list_response(p_body)
	
	if not list.is_empty():
		list.sort()
		get_model_list_request_succeeded.emit(list)
	else:
		get_model_list_request_failed.emit("No models found or invalid response format")
