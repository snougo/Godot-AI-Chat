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
		"ZhipuAI":
			headers.append("Authorization: Bearer %s" % _api_key)
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
		"ZhipuAI":
			return ZhipuAPI._build_chat_request_body(_model_name, final_messages_for_api, _temperature, _stream)
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
		"ZhipuAI":
			return ZhipuAPI._get_chat_url(_base_url)
		_:
			return ""


# 获取适用于特定 API 提供商的获取模型列表的 API 端点 URL。
static func get_models_url(_api_provider: String, _base_url: String, _api_key: String) -> String:
	match _api_provider:
		"OpenAI-Compatible":
			return OpenAICompatibleAPI._get_models_url(_base_url)
		"Google Gemini":
			return GeminiAPI._get_models_url(_base_url, _api_key)
		"ZhipuAI":
			# 智谱没有模型列表接口，连接检查时我们可以尝试请求一个简单的 endpoint 
			# 或者干脆让 NetworkManager 的 connection_check 对智谱直接放行
			return _base_url.path_join("v4/chat/completions")
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
		"ZhipuAI":
			return ZhipuAPI._parse_stream_chunk(_json_data)
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
		"OpenAI-Compatible", "ZhipuAI":
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
static func _get_all_tool_definitions(for_gemini: bool = false) -> Array:
	# 重构：直接调用注册中心获取所有工具定义
	return ToolRegistry.get_all_tool_definitions(for_gemini)


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
		
		# [修改] 遍历定义列表，构建 OpenAI 格式的 tools 数组
		var tools_list: Array = []
		var definitions = AiServiceAdapter._get_all_tool_definitions(false) # false = 小写类型
		
		for tool_def in definitions:
			tools_list.append({
				"type": "function",
				"function": tool_def
			})
			
		body["tools"] = tools_list
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
				var index = tool_call.get("index", 0) # [新增] 获取当前工具的索引
				var function = tool_call.get("function", {})
				
				# A. 检测到工具调用的开始 (通常包含 name)
				if function.has("name") and not function.name.is_empty():
					# [修复] 如果这不是第一个工具 (index > 0)，说明上一个工具刚刚结束
					# 我们需要先闭合上一个 JSON 代码块，再开始新的
					if index > 0:
						output_text += "\n}\n```\n"
					
					# 开始伪造新的 JSON 代码块
					output_text += "\n```json\n{\n  \"tool_name\": \"%s\",\n  \"arguments\": " % function.name
				
				# B. 检测到参数流 (arguments)
				if function.has("arguments") and not function.arguments.is_empty():
					output_text += function.arguments
			
			# 3. 检测结束信号
			# 当整个流结束时，闭合最后一个工具调用的代码块
			if finish_reason == "tool_calls" or finish_reason == "stop":
				# 只有当之前有工具调用时才闭合 (简单的判断逻辑)
				# 为了防止在普通文本对话结束时多输出一个闭合符，我们可以依赖 ChatBackend 的正则容错性，
				# 或者更严谨一点：finish_reason="tool_calls" 明确表示是工具调用结束。
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
				role = "function"
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
				{"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_ONLY_HIGH"},
				{"category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_ONLY_HIGH"},
				{"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_ONLY_HIGH"},
				{"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_ONLY_HIGH"}
			]
		}
		
		# [修改] Gemini 格式：tools 是一个包含 function_declarations 列表的对象
		body["tools"] = [{
			"function_declarations": AiServiceAdapter._get_all_tool_definitions(true) # true = 大写类型
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


# --- ZhipuAI API 的具体实现 ---
class ZhipuAPI:
	# 新增：手动维护的智谱模型列表
	# 免费用户的API目前不能使用4.6以及最新的4.7
	static func get_preset_models() -> Array[String]:
		return [
			"glm-4.5",
			"glm-4.5-air"
		]


	static func _build_chat_request_body(_model_name: String, _messages: Array, _temperature: float, _stream: bool) -> Dictionary:
		# 智谱 V4 完美兼容 OpenAI 格式
		var body: Dictionary = {
			"model": _model_name,
			"messages": _messages,
			"temperature": _temperature,
			"stream": _stream
		}
		
		# [新增] 显式要求返回 usage 信息（智谱 V4 支持此 OpenAI 兼容参数）
		if _stream:
			body["stream_options"] = {"include_usage": true}
		
		# 注入工具定义 (复用插件已有的工具系统)
		var tools_list: Array = []
		var definitions = AiServiceAdapter._get_all_tool_definitions(false)
		for tool_def in definitions:
			tools_list.append({"type": "function", "function": tool_def})
		
		body["tools"] = tools_list
		return body


	static func _get_chat_url(_base_url: String) -> String:
		# 逻辑：如果用户没填，用默认全称；如果填了，确保包含 /api/paas/
		var url = _base_url.strip_edges()
		
		if url.is_empty():
			return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
		
		# 智谱的 API 必须包含 api/paas
		if not url.contains("api/paas"):
			# 如果用户只填了 https://open.bigmodel.cn
			if not url.ends_with("/"): url += "/"
			url += "api/paas/"
		
		# 确保最终拼接 v4/chat/completions
		if not url.contains("v4/chat/completions"):
			if not url.ends_with("/"): url += "/"
			url += "v4/chat/completions"
		
		return url


	static func _get_models_url(_base_url: String, _api_key: String) -> String:
		# 同样修正模型列表的 URL（虽然我们现在是硬编码列表，但为了 connection_check 正常）
		var url = _base_url.strip_edges()
		if url.is_empty():
			return "https://open.bigmodel.cn/api/paas/v4/models"
		
		if not url.contains("api/paas"):
			if not url.ends_with("/"): url += "/"
			url += "api/paas/"
		
		return url.path_join("v4/models")


	static func _parse_stream_chunk(_json: Dictionary) -> String:
		# 智谱的流式结构与 OpenAI 完全一致
		return AiServiceAdapter.OpenAICompatibleAPI._parse_stream_chunk(_json)


	static func _parse_non_stream_response(_body: PackedByteArray) -> String:
		return AiServiceAdapter.OpenAICompatibleAPI._parse_non_stream_response(_body)
