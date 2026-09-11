@tool
class_name OpenAIChatCompletionsProvider
extends BaseOpenAIProvider

## OpenAI Chat Completions API Provider (/v1/chat/completions)
## 处理标准的 OpenAI Chat Completions 格式请求，包括 SSE 解析、Tool Calls 拼装等。


# --- Public Functions ---

## 获取请求的 URL
func get_request_url(p_base_url: String, p_model_name: String, _p_api_key: String, _p_stream: bool) -> String:
	var url: String = p_base_url.strip_edges()
	
	# 移除末尾斜杠
	if url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	
	# 如果模型名为空，说明是获取模型列表请求
	if p_model_name.is_empty():
		# 如果用户填的是 /v1/chat/completions，回退到 /v1/models
		if url.ends_with("/chat/completions"):
			return url.replace("/chat/completions", "/models")
		elif url.ends_with("/v1"):
			return url + "/models"
		else:
			# 默认假设
			return url + "/v1/models"
	
	# 正常的聊天请求
	if url.ends_with("/chat/completions"):
		return url
	elif url.ends_with("/v1"):
		return url + "/chat/completions"
	else:
		return url + "/v1/chat/completions"


## [子类覆写] 构建请求体 (Body)
func build_request_body_impl(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	var api_messages: Array[Dictionary] = []
	
	for msg: ChatMessage in p_messages:
		var msg_dict: Dictionary = _convert_message_to_api_format(msg)
		api_messages.append(msg_dict)
	
	# Kimi-K2.6必须温度值为1，否则会返回400错误代码
	var final_temperature: float = 1.0 if p_model_name == "kimi-k2.6" else p_temperature
	
	var body: Dictionary = {
		"model": p_model_name,
		"messages": api_messages,
		"temperature": snappedf(final_temperature, 0.1),
		"stream": p_stream
	}
	
	if not p_tool_definitions.is_empty():
		body["tools"] = p_tool_definitions
		body["tool_choice"] = "auto"
	
	if p_stream:
		body["stream_options"] = {"include_usage": true}
	
	return body


## 解析非流式响应 (完整 Body)
func parse_non_stream_response(p_body_bytes: PackedByteArray) -> Dictionary:
	var json_str: String = p_body_bytes.get_string_from_utf8()
	var json: Variant = JSON.parse_string(json_str)
	
	if json is Dictionary:
		if json.has("choices") and not json.choices.is_empty():
			# [修复 P2] 防御：choices[0] 可能不是 Dictionary
			var choice: Variant = json.choices[0]
			if choice is Dictionary:
				var msg: Dictionary = choice.get("message", {})
				# [修复 P2] 防御：message.content / tool_calls 可能是 JSON null
				var content: Variant = msg.get("content", "")
				var tool_calls: Variant = msg.get("tool_calls", [])
				var result: Dictionary = {
					"content": content if content is String else "",
					"tool_calls": tool_calls if tool_calls is Array else [],
					"role": msg.get("role", "assistant")
				}
				
				if msg.has("reasoning_content") and msg.reasoning_content is String:
					result["reasoning_content"] = msg.reasoning_content
				
				# [修复 P3] 透传非流式 usage（Chat Completions 本身就是 prompt/completion 格式）
				if json.has("usage") and json["usage"] is Dictionary:
					result["usage"] = json["usage"]
				
				return result
		elif json.has("error"):
			return {"error": str(json.error), "raw": json_str}
	
	return {"error": "Unknown response format", "raw": json_str}


## 解析单个流式数据块为协议无关增量
## 本协议所有信息均内联在 data 块中，无跨块状态
func parse_stream_chunk(p_raw_chunk: Dictionary) -> LLMStreamDelta:
	var result: LLMStreamDelta = LLMStreamDelta.new()
	
	# 1. 提取 Usage（Chat Completions 的 usage 本身即为 prompt/completion/total 结构）
	var raw_usage: Variant = p_raw_chunk.get("usage")
	if raw_usage is Dictionary:
		var usage_dict: Dictionary = raw_usage
		if not usage_dict.is_empty():
			result.usage = usage_dict.duplicate()
	
	var raw_choices: Variant = p_raw_chunk.get("choices")
	if not raw_choices is Array:
		return result
	
	var choices: Array = raw_choices
	if choices.is_empty():
		return result
	
	var raw_choice: Variant = choices[0]
	if not raw_choice is Dictionary:
		return result
	
	var raw_delta: Variant = (raw_choice as Dictionary).get("delta")
	if not raw_delta is Dictionary:
		return result
	
	var delta: Dictionary = raw_delta
	
	# 2. 提取文本 (Text)
	var raw_text: Variant = delta.get("content")
	if raw_text is String and not (raw_text as String).is_empty():
		result.content_delta = raw_text
	
	# 3. 提取思考 (Reasoning - Kimi/DeepSeek)
	var raw_reasoning: Variant = delta.get("reasoning_content")
	if raw_reasoning is String and not (raw_reasoning as String).is_empty():
		result.reasoning_delta = raw_reasoning
	
	# 4. 提取工具 (Tool Calls - 流式拼装，同一 index 视为同一槽位)
	var raw_tool_calls: Variant = delta.get("tool_calls")
	if raw_tool_calls is Array:
		for raw_call: Variant in (raw_tool_calls as Array):
			if raw_call is Dictionary:
				result.tool_call_deltas.append(_parse_tool_call_delta(raw_call))
	
	return result


# --- Private Functions ---

# 将单个 tool_calls 增量翻译为槽位增量
# 槽位键固定使用 index：Chat Completions 保证同一轮内 index 稳定且互异
# [param p_raw_call]: 原始 tool_calls[i] 字典
# [return]: LLMStreamDelta.tool_call_deltas 元素
func _parse_tool_call_delta(p_raw_call: Dictionary) -> Dictionary:
	var call_key: String = str(p_raw_call.get("index", 0))
	
	var call_id: String = ""
	var raw_id: Variant = p_raw_call.get("id")
	if raw_id is String:
		call_id = raw_id
	
	var name_fragment: String = ""
	var arguments_fragment: String = ""
	
	var raw_function: Variant = p_raw_call.get("function")
	if raw_function is Dictionary:
		var func_dict: Dictionary = raw_function
		
		var raw_name: Variant = func_dict.get("name")
		if raw_name is String and raw_name != null:
			name_fragment = raw_name
		
		var raw_arguments: Variant = func_dict.get("arguments")
		if raw_arguments is String and raw_arguments != null:
			arguments_fragment = raw_arguments
	
	var tool_delta: Dictionary = LLMStreamDelta.make_tool_call_start(call_key, call_id, name_fragment)
	tool_delta[LLMStreamDelta.FIELD_ARGUMENTS] = arguments_fragment
	return tool_delta


# 将 ChatMessage 转换为 OpenAI 格式的字典
func _convert_message_to_api_format(p_msg: ChatMessage) -> Dictionary:
	var dict: Dictionary = { "role": p_msg.role }
	
	# 1. 优先处理多模态 (仅 User 且有图)
	var has_images: bool = not p_msg.images.is_empty()
	
	if p_msg.role == "user" and has_images:
		var content_array: Array = []
		
		# 1.1 文本部分
		if not p_msg.content.is_empty():
			content_array.append({ "type": "text", "text": p_msg.content })
		
		# 1.2 新版多图数组处理
		for img: Dictionary in p_msg.images:
			var base64_str: String = Marshalls.raw_to_base64(img.data)
			var mime: String = img.get("mime", "image/png")
			content_array.append({
				"type": "image_url",
				"image_url": { "url": "data:%s;base64,%s" % [mime, base64_str] }
			})
		
		dict["content"] = content_array
	
	# 2. 普通文本处理
	else:
		var final_content: String = p_msg.content
		
		# [防御性修复] Tool 类型的消息内容绝对不能为空
		if p_msg.role == "tool" and final_content.is_empty():
			final_content = "SUCCESS"
		
		dict["content"] = final_content
	
	# 3. Name 字段
	if not p_msg.name.is_empty() and p_msg.role != "tool":
		dict["name"] = p_msg.name
	
	# 4. Tool Calls
	if not p_msg.tool_calls.is_empty():
		var valid_calls: Array = []
		for raw_call: Variant in p_msg.tool_calls:
			if not raw_call is Dictionary:
				continue
			var tc: Dictionary = raw_call
			if String(tc.get("id", "")) == "":
				continue
			
			# [修复 P1] 构造新字典，只保留 Chat Completions 需要的字段，
			# 避免把其他 Provider 的内部字段透传给 API
			var raw_func: Variant = tc.get("function", {})
			var func_dict: Dictionary = raw_func if raw_func is Dictionary else {}
			valid_calls.append({
				"id": tc.get("id", ""),
				"type": "function",
				"function": {
					"name": func_dict.get("name", ""),
					"arguments": func_dict.get("arguments", "")
				}
			})
		
		if not valid_calls.is_empty():
			dict["tool_calls"] = valid_calls
	
	# 5. Tool Call ID
	if not p_msg.tool_call_id.is_empty():
		dict["tool_call_id"] = p_msg.tool_call_id
	
	# 6. Reasoning Content (Kimi/DeepSeek)
	if p_msg.role == "assistant" and not p_msg.reasoning_content.is_empty():
		dict["reasoning_content"] = p_msg.reasoning_content
	
	return dict
