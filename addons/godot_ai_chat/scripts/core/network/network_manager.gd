@tool
class_name NetworkManager
extends Node

## 负责管理网络请求、Provider 初始化以及流式请求的生命周期。

# --- Signals ---

signal get_model_list_request_started
signal get_model_list_request_succeeded(model_list: Array[String])
signal get_model_list_request_failed(error: String)

## 流式相关信号
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
		var _model_list: Array[String] = current_provider.parse_model_list_response(PackedByteArray())
		get_model_list_request_succeeded.emit(_model_list)
		return
	
	# 其他提供商的正常处理逻辑
	var _url: String = current_provider.get_request_url(api_base_url, "", api_key, false)
	
	# OpenAI 兼容接口特例修正 - 获取模型列表需要特殊URL
	if current_provider is BaseOpenAIProvider:
		_url = api_base_url.path_join("v1/models")
	
	var _headers: PackedStringArray = current_provider.get_request_headers(api_key, false)
	
	if _http_request_node.request_completed.is_connected(_on_model_list_completed):
		_http_request_node.request_completed.disconnect(_on_model_list_completed)
	
	_http_request_node.request_completed.connect(_on_model_list_completed, CONNECT_ONE_SHOT)
	var _err: Error = _http_request_node.request(_url, _headers, HTTPClient.METHOD_GET)
	
	if _err != OK:
		get_model_list_request_failed.emit("Request failed: %s" % error_string(_err))


## 发起聊天流
func start_chat_stream(_messages: Array[ChatMessage]) -> void:
	if current_model_name.is_empty():
		chat_request_failed.emit("No model selected.")
		return
	
	if not _update_provider_config():
		chat_request_failed.emit("Configuration Error")
		return
	
	var _is_gemini: bool = (current_provider is GeminiProvider)
	var _tools: Array = ToolRegistry.get_all_tool_definitions(_is_gemini)
	
	var _body: Dictionary = current_provider.build_request_body(current_model_name, _messages, temperature, true, _tools)
	var _url: String = current_provider.get_request_url(api_base_url, current_model_name, api_key, true)
	var _headers: PackedStringArray = current_provider.get_request_headers(api_key, true)
	
	current_stream_request = StreamRequest.new(current_provider, _url, _headers, _body)
	
	current_stream_request.chunk_received.connect(func(_chunk: Dictionary): new_stream_chunk_received.emit(_chunk))
	current_stream_request.usage_received.connect(func(_usage: Dictionary): chat_usage_data_received.emit(_usage))
	current_stream_request.failed.connect(func(_err_msg: String): chat_request_failed.emit(_err_msg))
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
	var _settings: PluginSettings = ToolBox.get_plugin_settings()
	api_key = _settings.api_key
	api_base_url = _settings.api_base_url
	temperature = _settings.temperature
	
	match _settings.api_provider:
		"OpenAI-Compatible":
			current_provider = BaseOpenAIProvider.new()
		"Local-AI-Service":
			current_provider = LocalAIProvider.new()
		"ZhipuAI":
			current_provider = ZhipuAIProvider.new()
		"Google Gemini":
			current_provider = GeminiProvider.new()
		_:
			push_error("Unknown API Provider: %s" % _settings.api_provider)
			return false
	
	return true

# --- Signal Callbacks ---

func _on_model_list_completed(_result: int, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if _result != HTTPRequest.RESULT_SUCCESS or _response_code != 200:
		get_model_list_request_failed.emit("HTTP Error %d" % _response_code)
		return
	
	# 使用 Provider 进行多态解析
	var _list: Array[String] = current_provider.parse_model_list_response(_body)
	
	if not _list.is_empty():
		_list.sort() # 顺手排个序
		get_model_list_request_succeeded.emit(_list)
	else:
		get_model_list_request_failed.emit("No models found or invalid response format")
