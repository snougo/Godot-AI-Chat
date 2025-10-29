@tool
extends Node
class_name NetworkManager


# --- 请求状态信号 ---
# 当向API服务器拉取模型请求时发出
signal get_model_list_request
# 在发送聊天请求时发出
signal new_chat_request_sending

# --- 流式响应信号 ---
# 当收到新的文本数据块时发出
signal new_stream_chunk_received(chunk_text: String)
# 当数据流正常结束时发出
signal chat_stream_request_completed
# 当数据流主动被用户停止时发出
signal chat_stream_request_canceled

# --- 非流式请求成功信号 ---
# 当向API服务器上拉取模型请求成功时发出
signal connection_check_request_succeeded
# 当模型列表成功获取并更新后发出
signal get_model_list_request_succeeded(model_list: Array)
# 当模型的总结成功完成之后发出
signal summary_request_succeeded(summary_text: String)

# --- 请求失败信号 ---
# 当连线检查请求失败时发出
signal connection_check_request_failed(error: String)
# 当向API服务器上拉取模型请求失败时发出
signal get_model_list_request_failed(error: String)
# 当模型总结失败时发出
signal summary_request_failed(error: String)
# 当聊天请求失败时发出
signal chat_request_failed(error: String)

# --- 流式数据token相关信号 ---
signal chat_usage_data_received(usage_data: Dictionary)
signal prompt_tokens_consumed_on_failure(estimated_tokens: int)

const CONNECTION_CHECK_TIMEOUT: float = 10.0 # API服务连线检查的超时时间（秒）

# 用于非流式的API服务的连线检查的请求节点
@onready var connection_check_httprequest: HTTPRequest = $ConnectionCheckHTTPRequest
# 用于非流式的从API服务器上获取模型列表的请求节点
@onready var get_model_list_httprequest: HTTPRequest = $GetModelListHTTPRequest
# 用于非流式的向模型发出和接收总结
@onready var summary_httprequest: HTTPRequest = $SummaryHTTPRequest
# 用于处理流式聊天响应的自定义HTTP请求节点
@onready var chat_streamed_httprequest: ChatStreamedHTTPRequest = $ChatStreamedHTTPRequest

# --- API 参数 (从设置中加载) ---
var api_provider: String = ""
var api_base_url: String = ""
var api_key: String = ""
var temperature: float = 0.7
var current_model_name: String = ""

var user_prompt: String = ""
var _last_estimated_prompt_tokens: int = 0
var _usage_data_was_received: bool = false


func _ready() -> void:
	# 设置并连接用于连接检查的传统HTTPRequest
	connection_check_httprequest.timeout = CONNECTION_CHECK_TIMEOUT
	connection_check_httprequest.request_completed.connect(self._on_connection_check_request_completed)
	get_model_list_httprequest.timeout = CONNECTION_CHECK_TIMEOUT
	get_model_list_httprequest.request_completed.connect(self._on_get_model_list_request_completed)
	summary_httprequest.timeout = ToolBox.get_plugin_settings().network_timeout
	summary_httprequest.request_completed.connect(self._on_summary_request_completed)
	
	# 连接流式请求节点的信号
	if is_instance_valid(chat_streamed_httprequest):
		chat_streamed_httprequest.new_stream_chunk_received.connect(self._on_new_stream_chunk_received)
		chat_streamed_httprequest.stream_request_completed.connect(self._on_chat_stream_request_completed)
		chat_streamed_httprequest.stream_request_canceled.connect(self._on_chat_stream_interrupted)
		chat_streamed_httprequest.stream_request_failed.connect(self._on_chat_stream_interrupted)
		chat_streamed_httprequest.stream_usage_data_received.connect(self._on_stream_usage_data_received)
	else:
		push_error("[NetworkManager] ChatStreamedHTTPRequest Node is not found in the scene tree!")


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 在发送用户的提示词前先检查API服务的连线情况
func connection_check(_user_prompt: String) -> bool:
	print("[NetworkManager] API Connection Checking...")
	
	# 检查设置是否有效，如果无效则直接失败，不发送请求
	if not _set_http_request_base_parameters():
		return false
	
	var stream: bool = false
	var headers: PackedStringArray = AiServiceAdapter.get_request_headers(api_provider, api_key, stream)
	var url: String = AiServiceAdapter.get_models_url(api_provider, api_base_url, api_key)
	var error: Error = connection_check_httprequest.request(url, headers, HTTPClient.METHOD_GET)
	
	if error == OK:
		emit_signal("connection_check_request_succeeded", _user_prompt)
		return true
	else:
		# 如果连线检查失败，则交由API连线检查信号回调函数处理错误
		return false


# 用于从API服务器上获取模型列表并验证API设置
func get_model_list_from_api_service() -> void:
	print("[NetworkManager] Geting Model List from API Service...")
	emit_signal("get_model_list_request")
	
	# 检查设置是否有效，如果无效则直接失败，不发送请求
	if not _set_http_request_base_parameters():
		return
	
	var stream: bool = false
	var headers: PackedStringArray = AiServiceAdapter.get_request_headers(api_provider, api_key, stream)
	var url: String = AiServiceAdapter.get_models_url(api_provider, api_base_url, api_key)
	get_model_list_httprequest.request(url, headers, HTTPClient.METHOD_GET)


# 发送一个新的聊天请求，并期望一个流式响应。
func new_chat_stream_request(_context_for_ai: Array) -> void:
	if current_model_name.is_empty():
		emit_signal("chat_request_failed", "No AI model selected.")
		return
	
	# 检查设置是否有效，如果无效则直接失败，不发送请求
	if not _set_http_request_base_parameters():
		return
	
	# 只有在 API 不是 Gemini 时才执行本地估算，以避免重复计算
	# Gemini 会通过流返回精确的 token 数，我们应该只使用那个。
	if api_provider != "Google Gemini":
		_last_estimated_prompt_tokens = ToolBox.estimate_tokens_for_messages(_context_for_ai)
	else:
		# Gemini 依赖 API 返回的精确值
		_last_estimated_prompt_tokens = 0
	
	_usage_data_was_received = false
	_set_http_request_base_parameters()
	# 设置 stream=true 来请求流式输出
	var stream: bool = true 
	var headers: PackedStringArray = AiServiceAdapter.get_request_headers(api_provider, api_key, stream)
	var body_dict: Dictionary = AiServiceAdapter.build_chat_request_body(api_provider, current_model_name, _context_for_ai, temperature, stream)
	var url: String = AiServiceAdapter.get_chat_url(api_provider, api_base_url, current_model_name, api_key, stream)
	
	emit_signal("new_chat_request_sending")
	
	if is_instance_valid(chat_streamed_httprequest):
		chat_streamed_httprequest.start_new_stream_request(url, headers, JSON.stringify(body_dict), api_provider)
	else:
		emit_signal("chat_request_failed", "ChatStreamedHTTPRequest Node is not found in the scene tree!")


# 停止当前的流式请求
func cancel_stream_request() -> void:
	if is_instance_valid(chat_streamed_httprequest):
		chat_streamed_httprequest.cancel_current_stream_request()


# 更新当前选择的模型名称。
func update_model_name(new_model_name: String) -> void:
	current_model_name = new_model_name


# 发起一个非流式的总结请求
func request_summary(chat_history: Array) -> void:
	if current_model_name.is_empty():
		emit_signal("summary_request_failed", "No AI model selected for summarization.")
		return
	
	if not _set_http_request_base_parameters():
		return
	
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	var summarization_prompt: String = settings.summarization_prompt
	
	# 格式化历史记录为Markdown文本
	var history_text: String = ""
	for message in chat_history:
		if message.role == "system": continue
		
		match message.role:
			"user": history_text += "### 🧑‍💻 User\n"
			"assistant": history_text += "### 🤖 AI Response\n"
			"tool": history_text += "### ⚙️ Tool Output\n"
		
		history_text += message.content + "\n\n>------------\n\n"
	
	# 构建请求的上下文
	var context_for_summary: Array = [
		{"role": "system", "content": summarization_prompt},
		{"role": "user", "content": history_text.strip_edges()}
	]
	
	var stream: bool = false # 明确指定为非流式
	var headers: PackedStringArray = AiServiceAdapter.get_request_headers(api_provider, api_key, stream)
	var body_dict: Dictionary = AiServiceAdapter.build_chat_request_body(api_provider, current_model_name, context_for_summary, temperature, stream)
	var url: String = AiServiceAdapter.get_chat_url(api_provider, api_base_url, current_model_name, api_key, stream)
	
	summary_httprequest.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body_dict))


#==============================================================================
# ## 内部函数 ##
#==============================================================================

# 从插件设置文件加载最新的API参数
func _set_http_request_base_parameters() -> bool:
	var plugin_settings: PluginSettings = ToolBox.get_plugin_settings()
	api_provider = plugin_settings.api_provider
	api_base_url = plugin_settings.api_base_url
	api_key = plugin_settings.api_key
	temperature = plugin_settings.temperature
	
	# 基本的设置验证
	if api_provider.contains("Google Gemini") and not api_base_url.contains("googleapis"):
		emit_signal("connection_check_request_failed", "API Provider is Gemini but API Address seems incorrect.")
		return false
	if api_provider.contains("OpenAI-Compatible") and api_base_url.contains("googleapis"):
		emit_signal("connection_check_request_failed", "API Provider is OpenAI-Compatible but API Address seems incorrect.")
		return false
	if api_base_url.is_empty():
		emit_signal("connection_check_request_failed", "API Base Url is not set in Settings.")
		return false
	if api_key.is_empty() and api_base_url != "http://127.0.0.1:1234":
		emit_signal("connection_check_request_failed", "API Key is not set in Settings.")
		return false
	
	return true


# 统一处理和格式化各种网络请求失败的原因
func _handle_request_failure(_result: HTTPRequest.Result, _response_code: int, _body: PackedByteArray) -> String:
	var error_message: String
	match _result:
		HTTPRequest.RESULT_TIMEOUT: error_message = "Request timed out. Check your network or increase the timeout in settings."
		HTTPRequest.RESULT_CANT_CONNECT: error_message = "Connection failed. Is the API URL correct and the server running?"
		HTTPRequest.RESULT_CANT_RESOLVE: error_message = "Cannot resolve hostname. Is the API URL spelled correctly?"
		HTTPRequest.RESULT_CONNECTION_ERROR: error_message = "Connection error. A stable data transfer could not be established."
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR: error_message = "TLS handshake failed. The URL might need 'http' instead of 'https', or the server certificate is invalid."
		HTTPRequest.RESULT_REDIRECT_LIMIT_REACHED: error_message = "Redirect limit reached. The API URL might be misconfigured."
		HTTPRequest.RESULT_REQUEST_FAILED: error_message = "Request failed. The engine failed to send the request."
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED: error_message = "Response body size limit exceeded. The response from the server was too large."
	
	if error_message.is_empty() and _response_code > 0:
		match _response_code:
			400: error_message = "Bad Request (HTTP 400). The request may be malformed."
			401: error_message = "Unauthorized (HTTP 401). Check if your API Key is correct and valid."
			403: error_message = "Forbidden (HTTP 403). You don't have permission to access this resource. Check API Key permissions."
			404: error_message = "Not Found (HTTP 404). The API endpoint could not be found. Check the API URL."
			429: error_message = "Too Many Requests (HTTP 429). You have hit the API rate limit. Please wait and try again later."
			500: error_message = "Internal Server Error (HTTP 500). The API provider's server had a problem."
			503: error_message = "Service Unavailable (HTTP 503). The API provider's service is temporarily down."
			_:   error_message = "Request failed (HTTP %d)." % _response_code
		
		if not _body.is_empty():
			var reason = ""
			var response_text = _body.get_string_from_utf8()
			var json_data = JSON.parse_string(response_text)
			if json_data:
				if json_data is Dictionary:
					if json_data.has("error"):
						if json_data["error"] is Dictionary:
							if json_data["error"].has("message"):
								reason = str(json_data["error"]["message"])
					elif json_data.has("message"):
						reason = str(json_data["message"])
				elif json_data is String:
					reason = json_data
			else:
				reason = response_text.left(200) + ("..." if response_text.length() > 200 else "")
			if not reason.is_empty(): error_message += "\nReason: %s" % reason
	elif error_message.is_empty():
		error_message = "An unknown network error occurred (Result code: %d)" % _result
	
	return error_message


#==============================================================================
# ## 信号回调函数 ##
#==============================================================================

# 处理API服务连线检查请求完成的事情
func _on_connection_check_request_completed(_result: HTTPRequest.Result, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if not (_result == HTTPRequest.RESULT_SUCCESS and _response_code == 200):
		var err_msg: String = _handle_request_failure(_result, _response_code, _body)
		emit_signal("connection_check_request_failed", err_msg)


# 处理模型列表获取请求完成的事件
func _on_get_model_list_request_completed(_result: HTTPRequest.Result, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if _result == HTTPRequest.RESULT_SUCCESS and _response_code == 200:
		var model_data_array: Array = AiServiceAdapter.parse_models_response(api_provider, _body)
		var model_list: Array[String] = []
		
		for model_info in model_data_array:
			if typeof(model_info) == TYPE_DICTIONARY:
				if api_provider == "OpenAI-Compatible" and model_info.has("id"):
					model_list.append(model_info.id)
				elif api_provider == "Google Gemini" and model_info.has("name"):
					# Gemini模型名称需要移除 "models/" 前缀
					model_list.append(model_info.name.trim_prefix("models/"))
		
		model_list.sort()
		emit_signal("get_model_list_request_succeeded", model_list)
	else:
		var err_msg: String = _handle_request_failure(_result, _response_code, _body)
		emit_signal("get_model_list_request_failed", err_msg)


# 新增：处理总结请求完成的事件
func _on_summary_request_completed(_result: HTTPRequest.Result, _response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if _result == HTTPRequest.RESULT_SUCCESS and _response_code == 200:
		var summary_text: String = AiServiceAdapter.parse_non_stream_chat_response(api_provider, _body)
		if summary_text.begins_with("[ERROR]"):
			emit_signal("summary_request_failed", summary_text)
		else:
			emit_signal("summary_request_succeeded", summary_text)
	else:
		var err_msg: String = _handle_request_failure(_result, _response_code, _body)
		emit_signal("summary_request_failed", err_msg)


# 收到流式数据块时，直接转发信号
func _on_new_stream_chunk_received(chunk_text: String):
	emit_signal("new_stream_chunk_received", chunk_text)


# 流式传输正常结束时，直接转发信号
func _on_chat_stream_request_completed():
	# 如果流正常结束，但我们从未收到过真实的 usage 数据，
	# 这意味着我们连接的是一个不支持此功能的服务。
	# 在这种情况下，我们必须使用估算值作为回退。
	if not _usage_data_was_received and _last_estimated_prompt_tokens > 0:
		print("[NetworkManager] Stream completed without usage data. Committing estimated tokens.")
		emit_signal("prompt_tokens_consumed_on_failure", _last_estimated_prompt_tokens)
	
	# 清理估算值，无论是否使用
	_last_estimated_prompt_tokens = 0
	
	emit_signal("chat_stream_request_completed")


# 流式数据传输完毕后发送信号
func _on_stream_usage_data_received(usage_data: Dictionary) -> void:
	print("[DEBUG 2] NetworkManager: Forwarding usage data: ", usage_data)
	_usage_data_was_received = true
	emit_signal("chat_usage_data_received", usage_data)


# 流式数据传输中断时发送信号
func _on_chat_stream_interrupted(error_message: String = ""):
	if _last_estimated_prompt_tokens > 0:
		emit_signal("prompt_tokens_consumed_on_failure", _last_estimated_prompt_tokens)
		_last_estimated_prompt_tokens = 0
	
	if not error_message.is_empty():
		emit_signal("chat_request_failed", error_message)
	else:
		emit_signal("chat_stream_request_canceled")
