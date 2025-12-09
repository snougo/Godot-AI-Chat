extends RefCounted
class_name AiServiceAdapter


#==============================================================================
# ## 公共函数 ##
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
			# [修复] 将 API Key 放入 Header 中，而不是 URL
			headers.append("x-goog-api-key: %s" % _api_key)
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
# ## 内部私有函数 ##
#==============================================================================

# [优化] 统一的工具定义函数
# for_gemini: 如果为 true，则使用大写类型 (OBJECT, STRING)，否则使用标准小写 (object, string)
static func _get_tool_definition(for_gemini: bool = false) -> Dictionary:
	var type_object = "OBJECT" if for_gemini else "object"
	var type_string = "STRING" if for_gemini else "string"
	
	return {
		"name": "get_context",
		"description": "Retrieve context information from the Godot project. Use this to read folder structures, script content, scene trees, or documentation files.",
		"parameters": {
			"type": type_object,
			"properties": {
				"context_type": {
					"type": type_string,
					"enum": ["folder_structure", "scene_tree", "gdscript", "text-based_file"],
					"description": "The type of context to retrieve."
				},
				"path": {
					"type": type_string,
					"description": "The relative path to the file or directory, starting with res://"
				}
			},
			"required": ["context_type", "path"]
		}
	}


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
		# 1. 清洗逻辑：OpenAI 的 tool 消息不需要 'name' 字段，只需 'tool_call_id'
		var clean_messages: Array = []
		for msg in _messages:
			if msg.get("role") == "tool" and msg.has("name"):
				var clean_msg = msg.duplicate()
				clean_msg.erase("name")
				clean_messages.append(clean_msg)
			else:
				clean_messages.append(msg)
		
		var body: Dictionary = {
			"model": _model_name,
			"messages": clean_messages,
			"temperature": _temperature,
			"stream": _stream
		}
		
		# [新增] 正式向 OpenAI 声明工具
		body["tools"] = [{
			"type": "function",
			"function": AiServiceAdapter._get_tool_definition(false)
		}]
		body["tool_choice"] = "auto"
		
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
		var output_text: String = ""
		
		if _json.has("choices") and not _json.choices.is_empty():
			var choice = _json.choices[0]
			var delta = choice.get("delta", {})
			var finish_reason = choice.get("finish_reason")
			
			# 1. 处理普通文本内容
			if delta.has("content") and delta.content is String:
				output_text += delta.content
			
			# 2. 处理工具调用 (Native Tool Call) -> 桥接到 Markdown JSON
			if delta.has("tool_calls") and not delta.tool_calls.is_empty():
				var tool_call = delta.tool_calls[0]
				var function = tool_call.get("function", {})
				
				# A. 检测到工具调用的开始 (通常包含 name)
				if function.has("name") and not function.name.is_empty():
					# 开始伪造 JSON 代码块
					# 注意：这里我们手动构造 JSON 的前半部分
					output_text += "\n```json\n{\n  \"tool_name\": \"%s\",\n  \"arguments\": " % function.name
				
				# B. 检测到参数流 (arguments)
				if function.has("arguments") and not function.arguments.is_empty():
					# 直接将参数片段流式输出。
					# 因为 OpenAI 的 arguments 本身就是 JSON 对象的字符串表示，
					# 所以直接拼接进去，最终会形成 { "tool_name": "...", "arguments": { ... } } 的结构
					output_text += function.arguments
			
			# 3. 检测结束信号
			# 如果是因为 tool_calls 结束，或者是 stop，我们需要闭合 JSON 代码块
			if finish_reason == "tool_calls" or finish_reason == "stop":
				# 只有当我们之前可能在输出工具调用时才闭合。
				# 由于这是无状态函数，我们无法确切知道上一帧是否是工具调用。
				# 但通常 finish_reason 出现时，delta 是空的。
				# 为了保险，我们依赖 ChatBackend 的容错性，或者这里做一个简单的假设：
				# 如果这个 chunk 没有任何 content，但有 finish_reason，且之前有过 tool_calls 逻辑...
				# 实际上，最稳妥的方式是：如果这一帧有 tool_calls 或者是 tool_calls 结束，我们尝试闭合。
				
				# 简化策略：在 OpenAI 中，finish_reason="tool_calls" 意味着工具参数传输完毕。
				if finish_reason == "tool_calls":
					output_text += "\n}\n```\n"
		
		return output_text


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
		
		# 分离系统提示
		if not _messages.is_empty() and _messages[0]["role"] == "system":
			system_instruction = {"parts": [{"text": _messages[0]["content"]}]}
			conversation_messages = _messages.slice(1)
		else:
			conversation_messages = _messages
		
		# 转换消息格式
		for msg in conversation_messages:
			var role: String = "user"
			var parts: Array = []
			
			if msg["role"] == "assistant":
				role = "model"
				# 处理模型发起的工具调用
				if msg.has("tool_calls") and not msg["tool_calls"].is_empty():
					for tool_call in msg["tool_calls"]:
						var function_data = tool_call.get("function", {})
						var args_str = function_data.get("arguments", "{}")
						var args_obj = JSON.parse_string(args_str)
						if args_obj == null: args_obj = {}
						
						# 构建 Part 对象
						var part_obj = {
							"functionCall": {
								"name": function_data.get("name", ""),
								"args": args_obj
							}
						}
						
						# [修复] 将 thoughtSignature 放在 Part 对象中，与 functionCall 平级
						if tool_call.has("gemini_thought_signature"):
							# 注意：发送给 API 时必须使用 "thoughtSignature" 这个键名
							part_obj["thoughtSignature"] = tool_call["gemini_thought_signature"]
						
						parts.append(part_obj)
				else:
					parts.append({"text": msg.get("content", "")})
			
			elif msg["role"] == "tool":
				role = "user"
				# 处理工具执行结果
				parts.append({
					"functionResponse": {
						"name": msg.get("name", "unknown_tool"),
						"response": {
							"name": msg.get("name", "unknown_tool"),
							"content": msg.get("content", "")
						}
					}
				})
			
			else:
				# 普通用户消息
				role = "user"
				parts.append({"text": msg.get("content", "")})
			
			if not parts.is_empty():
				gemini_contents.append({"role": role, "parts": parts})
		
		var body: Dictionary = {
			"contents": gemini_contents,
			"generationConfig": {"temperature": _temperature},
			# [新增] 放宽安全设置
			"safetySettings": [
				{"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_NONE"},
				{"category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_NONE"},
				{"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_NONE"},
				{"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_NONE"}
			]
		}
		
		# [新增] 发送工具定义
		body["tools"] = [{
			"function_declarations": [AiServiceAdapter._get_tool_definition(true)]
		}]
		
		if not system_instruction.is_empty():
			body["system_instruction"] = system_instruction
		
		return body


	static func _get_chat_url(_base_url: String, _model_name: String, _api_key: String, _stream: bool) -> String:
		# 根据是否流式请求选择不同的端点
		var action: String = "streamGenerateContent" if _stream else "generateContent"
		var url_with_version: String = _base_url.path_join("v1beta/models")
		var final_url: String = url_with_version.path_join(_model_name)
		return "{url}:{action}".format({"url": final_url, "action": action})


	static func _get_models_url(_base_url: String, _api_key: String) -> String:
		var url_with_version: String = _base_url.path_join("v1beta/models")
		return url_with_version


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
					# 情况 1: 普通文本
					if part.has("text"):
						text_chunk += part.text
					
					# 情况 2: 原生工具调用
					if part.has("functionCall"):
						var func_call = part.functionCall
						var func_name = func_call.get("name", "")
						var func_args = func_call.get("args", {})
						
						# [修复] 从 Part 层级获取 thoughtSignature
						# 注意：API 返回时可能是 thoughtSignature (驼峰)
						var signature = null
						if part.has("thoughtSignature"):
							signature = part["thoughtSignature"]
						# 防御性编程：也检查一下 functionCall 内部，虽然报错说不在那里，但万一 API 变动
						elif func_call.has("thoughtSignature"):
							signature = func_call["thoughtSignature"]
						
						# 构造伪装的 JSON 字符串
						var tool_payload = {
							"tool_name": func_name,
							"arguments": func_args
						}
						
						# 将签名藏在 payload 中
						if signature != null:
							tool_payload["gemini_thought_signature"] = signature
						
						text_chunk += "\n```json\n" + JSON.stringify(tool_payload) + "\n```\n"
		
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
