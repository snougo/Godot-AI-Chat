extends RefCounted
class_name AiServiceAdapter


#==============================================================================
# ## 全局静态函数 ##
#==============================================================================

# 获取适用于特定 API 提供商的 HTTP 请求头。
static func get_request_headers(_api_provider: String, _api_key: String, _stream: bool) -> PackedStringArray:
	var headers: PackedStringArray = ["Content-Type: application/json"]
	match _api_provider:
		"OpenAI-Compatible":
			# 流式期望 SSE
			if _stream:
				headers.append("Accept: text/event-stream")
			headers.append_array(OpenAICompatibleAPI._get_additional_headers(_api_key))
		"Google Gemini":
			pass # Gemini 不需要额外的认证头，API Key 在 URL 中
	return headers


# 构建适用于特定 API 提供商的聊天请求体（body）。
static func build_chat_request_body(_api_provider: String, _model_name: String, _messages: Array, _temperature: float, _stream: bool) -> Dictionary:
	# 统一处理内部使用的 "tool" 角色，将其转换成 API 能理解的 "user" 角色。
	var final_messages_for_api: Array = []
	for message in _messages:
		if message["role"] == "tool":
			# 如果这是一个现代的、带ID的工具响应，则原封不动地传递它。
			if message.has("tool_call_id"):
				final_messages_for_api.append(message)
			# 否则，如果它是一个不带ID的旧式工具消息，为了向后兼容，
			# 将其转换为 "user" 消息。
			else:
				final_messages_for_api.append({"role": "user", "content": message.get("content", "")})
		else:
			final_messages_for_api.append(message)
	
	match _api_provider:
		"OpenAI-Compatible":
			return OpenAICompatibleAPI._build_chat_request_body(_model_name, final_messages_for_api, _temperature, _stream)
		"Google Gemini":
			return GeminiAPI._build_chat_request_body(_model_name, final_messages_for_api, _temperature, _stream)
		_:
			push_error("Unsupported API provider in build_chat_request_body: %s" % _api_provider)
			return {}


# 获取适用于特定 API 提供商的聊天 API 端点 URL。
static func get_chat_url(_api_provider: String, _base_url: String, _model_name: String, _api_key: String, _stream: bool) -> String:
	match _api_provider:
		"OpenAI-Compatible":
			return OpenAICompatibleAPI._get_chat_url(_base_url)
		"Google Gemini":
			return GeminiAPI._get_chat_url(_base_url, _model_name, _api_key, _stream)
		_:
			return ""


# 获取适用于特定 API 提供商的获取模型列表的 API 端点 URL。
static func get_models_url(_api_provider: String, _base_url: String, _api_key: String) -> String:
	match _api_provider:
		"OpenAI-Compatible":
			return OpenAICompatibleAPI._get_models_url(_base_url)
		"Google Gemini":
			return GeminiAPI._get_models_url(_base_url, _api_key)
		_:
			return ""


# 解析特定 API 提供商返回的模型列表响应。
static func parse_models_response(_api_provider: String, _body: PackedByteArray) -> Array:
	match _api_provider:
		"OpenAI-Compatible":
			return OpenAICompatibleAPI._parse_models_response(_body)
		"Google Gemini":
			return GeminiAPI._parse_models_response(_body)
		_:
			return []


# 解析特定 API 提供商返回的流式聊天响应中的单个数据块（chunk）。
static func parse_stream_chunk(_api_provider: String, _json_data: Dictionary) -> String:
	match _api_provider:
		"OpenAI-Compatible":
			return OpenAICompatibleAPI._parse_stream_chunk(_json_data)
		"Google Gemini":
			return GeminiAPI._parse_stream_chunk(_json_data)
		_:
			return ""


# 解析特定 API 提供商返回的非流式聊天响应。
static func parse_non_stream_chat_response(_api_provider: String, _body: PackedByteArray) -> String:
	match _api_provider:
		"OpenAI-Compatible":
			return OpenAICompatibleAPI._parse_non_stream_response(_body)
		"Google Gemini":
			return GeminiAPI._parse_non_stream_response(_body)
		_:
			return "[ERROR] Unknown provider in parse_non_stream_chat_response"


static func parse_stream_usage_chunk(_api_provider: String, _json_data: Dictionary) -> Dictionary:
	var usage_data: Dictionary = {}
	
	match _api_provider:
		"OpenAI-Compatible":
			if _json_data.has("usage") and _json_data.usage is Dictionary:
				var usage = _json_data.usage
				if usage.has("prompt_tokens") and usage.has("completion_tokens"):
					return {
						"prompt_tokens": int(usage.prompt_tokens),
						"completion_tokens": int(usage.completion_tokens)
					}
		"Google Gemini":
			# Gemini 的 usageMetadata 可能出现在每个块中，但只有最后一个是完整的
			if _json_data.has("usageMetadata") and _json_data.usageMetadata is Dictionary:
				var metadata = _json_data.usageMetadata
				# 我们只关心包含 completion (candidates) token 计数的那个块，因为它代表流的结束
				if metadata.has("promptTokenCount") and metadata.has("candidatesTokenCount"):
					return {
						"prompt_tokens": int(metadata.promptTokenCount),
						"completion_tokens": int(metadata.candidatesTokenCount)
					}
	return {}


#==============================================================================
# ## 内部私有实现 ##
#==============================================================================

# --- OpenAI 兼容 API 的具体实现 ---
class OpenAICompatibleAPI:
	static func _get_additional_headers(_api_key: String) -> PackedStringArray:
		var headers: PackedStringArray = []
		# 明确告知服务器我们不接受任何压缩格式，只接受原始的、未经压缩的响应。
		# 这可以从根本上避免因处理 Gzip 压缩流而导致的 UTF-8 解析错误。
		headers.append("Accept-Encoding: identity")
		
		if not _api_key.is_empty():
			headers.append("Authorization: Bearer " + _api_key)
		return headers


	static func _build_chat_request_body(_model_name: String, _messages: Array, _temperature: float, _stream: bool) -> Dictionary:
		var body: Dictionary = {
			"model": _model_name,
			"messages": _messages,
			"temperature": _temperature,
			"stream": _stream
		}
		# 如果是流式请求，向这个 `body` 字典中添加新的键
		if _stream:
			body["stream_options"] = {"include_usage": true}
		
		return body


	static func _get_chat_url(_base_url: String) -> String:
		return _base_url.path_join("v1/chat/completions")


	static func _get_models_url(_base_url: String) -> String:
		return _base_url.path_join("v1/models")


	static func _parse_models_response(_body: PackedByteArray) -> Array:
		var json_data = JSON.parse_string(_body.get_string_from_utf8())
		if typeof(json_data) == TYPE_DICTIONARY and json_data.has("data"):
			return json_data.data
		return []


	static func _parse_stream_chunk(_json: Dictionary) -> String:
		if _json.has("choices") and not _json.choices.is_empty():
			var choice = _json.choices[0]
			if choice.has("delta") and choice.delta.has("content"):
				var content = choice.delta.get("content")
				if content is String:
					return content
		return ""


	static func _parse_non_stream_response(_body: PackedByteArray) -> String:
		var json_data = JSON.parse_string(_body.get_string_from_utf8())
		if typeof(json_data) == TYPE_DICTIONARY and json_data.has("choices") and not json_data.choices.is_empty():
			var choice = json_data.choices[0]
			if choice.has("message") and choice.message.has("content"):
				return choice.message.content
		return "[ERROR] Could not parse summary from OpenAI-Compatible response."



# --- Google Gemini API 的具体实现 ---
class GeminiAPI:
	static func _build_chat_request_body(_model_name: String, _messages: Array, _temperature: float, _stream: bool) -> Dictionary:
		var gemini_contents: Array = []
		var system_instruction: Dictionary = {}
		var conversation_messages: Array = []
		
		# 分离系统提示和对话消息
		if not _messages.is_empty() and _messages[0]["role"] == "system":
			system_instruction = {"parts": [{"text": _messages[0]["content"]}]}
			conversation_messages = _messages.slice(1)
		else:
			conversation_messages = _messages
		
		# 转换消息格式
		for msg in conversation_messages:
			var role: String = "model" if msg["role"] == "assistant" else "user"
			var content_part: Dictionary = {"parts": [{"text": msg["content"]}]}
			gemini_contents.append({"role": role, "parts": content_part.parts})
		
		var body: Dictionary = {
			"contents": gemini_contents,
			"generationConfig": {"temperature": _temperature}
		}
		if not system_instruction.is_empty():
			body["system_instruction"] = system_instruction
		
		return body


	static func _get_chat_url(_base_url: String, _model_name: String, _api_key: String, _stream: bool) -> String:
		# 根据是否流式请求选择不同的端点
		var action: String = "streamGenerateContent" if _stream else "generateContent"
		var url_with_version: String = _base_url.path_join("v1beta/models")
		var final_url: String = url_with_version.path_join(_model_name)
		return "{url}:{action}?key={key}".format({"url": final_url, "action": action, "key": _api_key})


	static func _get_models_url(_base_url: String, _api_key: String) -> String:
		var url_with_version: String = _base_url.path_join("v1beta/models")
		return "{url}?key={key}".format({"url": url_with_version, "key": _api_key})


	static func _parse_models_response(_body: PackedByteArray) -> Array:
		var json_data = JSON.parse_string(_body.get_string_from_utf8())
		if typeof(json_data) == TYPE_DICTIONARY and json_data.has("models"):
			return json_data.models
		return []


	static func _parse_stream_chunk(_json: Dictionary) -> String:
		var text_chunk: String = ""
		if _json.has("candidates") and not _json.candidates.is_empty():
			var candidate = _json.candidates[0]
			if candidate.has("content") and candidate.content.has("parts"):
				for part in candidate.content.parts:
					if part.has("text"):
						text_chunk += part.text
		return text_chunk


	static func _parse_non_stream_response(_body: PackedByteArray) -> String:
		var json_data = JSON.parse_string(_body.get_string_from_utf8())
		var text_chunk: String = ""
		if json_data.has("candidates") and not json_data.candidates.is_empty():
			var candidate = json_data.candidates[0]
			if candidate.has("content") and candidate.content.has("parts"):
				for part in candidate.content.parts:
					if part.has("text"):
						text_chunk += part.text
		if not text_chunk.is_empty():
			return text_chunk
		return "[ERROR] Could not parse summary from Gemini response."
