@tool
extends Node
class_name NetworkManager

# --- 信号 ---
signal get_model_list_request_started
signal get_model_list_request_succeeded(model_list: Array)
signal get_model_list_request_failed(error: String)

# 流式相关信号
signal new_chat_request_sending
signal new_stream_chunk_received(chunk: Dictionary)
signal chat_stream_request_completed
signal chat_stream_request_canceled
signal chat_request_failed(error: String)
signal chat_usage_data_received(usage: Dictionary)

# --- 节点引用 ---
@onready var http_request_node: HTTPRequest = $HTTPRequest

# --- 内部属性 ---
var current_provider: BaseLLMProvider = null
var current_stream_request: StreamRequest = null

# 缓存设置
var api_key: String = ""
var api_base_url: String = ""
var temperature: float = 0.7
var current_model_name: String = ""


func _ready() -> void:
	http_request_node.timeout = 10.0


# --- 核心：初始化 Provider ---
func _update_provider_config() -> bool:
	var settings = ToolBox.get_plugin_settings()
	api_key = settings.api_key
	api_base_url = settings.api_base_url
	temperature = settings.temperature
	
	match settings.api_provider:
		"OpenAI-Compatible":
			current_provider = BaseOpenAIProvider.new()
		"ZhipuAI":
			current_provider = ZhipuAIProvider.new()
		"Google Gemini":
			current_provider = GeminiProvider.new()
		_:
			push_error("Unknown API Provider: %s" % settings.api_provider)
			return false
	
	return true


# --- 公共功能 ---

# 获取模型列表
func get_model_list() -> void:
	if not _update_provider_config():
		emit_signal("get_model_list_request_failed", "Invalid Provider Configuration")
		return
	
	# 检查 Base URL 是否为空，如果是则直接返回，不报错也不发送请求
	# 因为这通常意味着用户刚安装插件，还没配置
	if api_base_url.is_empty():
		emit_signal("get_model_list_request_failed", "Please configure API Base URL in settings.")
		return
	
	emit_signal("get_model_list_request_started")
	
	if current_provider is ZhipuAIProvider:
		get_tree().create_timer(0.5).timeout.connect(func():
			emit_signal("get_model_list_request_succeeded", ["glm-4", "glm-4-air", "glm-4-flash", "glm-4-plus"])
		)
		return
	
	var url = current_provider.get_request_url(api_base_url, "", api_key, false)
	
	# OpenAI 兼容接口特例修正
	if current_provider is BaseOpenAIProvider:
		url = api_base_url.path_join("v1/models")
	
	var headers = current_provider.get_request_headers(api_key, false)
	
	http_request_node.request_completed.connect(_on_model_list_completed, CONNECT_ONE_SHOT)
	var err = http_request_node.request(url, headers, HTTPClient.METHOD_GET)
	
	if err != OK:
		emit_signal("get_model_list_request_failed", "Request failed: %s" % error_string(err))


# 发起聊天流
func start_chat_stream(messages: Array[ChatMessage]) -> void:
	if current_model_name.is_empty():
		emit_signal("chat_request_failed", "No model selected.")
		return
	
	if not _update_provider_config():
		emit_signal("chat_request_failed", "Configuration Error")
		return
	
	var is_gemini: bool = (current_provider is GeminiProvider)
	var tools: Array = ToolRegistry.get_all_tool_definitions(is_gemini)
	
	var body: Dictionary = current_provider.build_request_body(current_model_name, messages, temperature, true, tools)
	var url: String = current_provider.get_request_url(api_base_url, current_model_name, api_key, true)
	var headers: PackedStringArray = current_provider.get_request_headers(api_key, true)
	
	current_stream_request = StreamRequest.new(current_provider, url, headers, body)
	
	current_stream_request.chunk_received.connect(func(chunk): emit_signal("new_stream_chunk_received", chunk))
	current_stream_request.usage_received.connect(func(usage): emit_signal("chat_usage_data_received", usage))
	current_stream_request.failed.connect(func(err): emit_signal("chat_request_failed", err))
	current_stream_request.finished.connect(func(): emit_signal("chat_stream_request_completed"))
	
	emit_signal("new_chat_request_sending")
	current_stream_request.start()


# 停止流
func cancel_stream() -> void:
	if current_stream_request:
		current_stream_request.cancel()
		emit_signal("chat_stream_request_canceled")


# --- 回调处理 ---

func _on_model_list_completed(result, response_code, _headers, body):
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		emit_signal("get_model_list_request_failed", "HTTP Error %d" % response_code)
		return
	
	# 使用 Provider 进行多态解析
	var list: Array[String] = current_provider.parse_model_list_response(body)
	
	if not list.is_empty():
		list.sort() # 顺手排个序
		emit_signal("get_model_list_request_succeeded", list)
	else:
		emit_signal("get_model_list_request_failed", "No models found or invalid response format")
