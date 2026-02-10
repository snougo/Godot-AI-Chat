@tool
class_name OpenAICompatibleProvider
extends BaseLLMProvider

## OpenAI 兼容接口的基类实现
##
## 处理标准的 OpenAI 格式请求，包括 SSE 解析、Tool Calls 拼装等。

# --- Public Functions ---

## 返回该 Provider 使用的流式解析协议
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


## 获取 HTTP 请求头
func get_request_headers(p_api_key: String, p_stream: bool) -> PackedStringArray:
	var headers: PackedStringArray = ["Content-Type: application/json"]
	headers.append("Accept-Encoding: identity")
	
	if p_stream:
		headers.append("Accept: text/event-stream")
	
	if not p_api_key.is_empty():
		headers.append("Authorization: Bearer " + p_api_key)
	
	return headers


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


## 构建请求体 (Body)
func build_request_body(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	var api_messages: Array[Dictionary] = []
	
	for msg in p_messages:
		var msg_dict: Dictionary = _convert_message_to_api_format(msg)
		api_messages.append(msg_dict)
	
	# Kimi-K2.5必须温度值为1，否则会返回400错误代码
	var final_temperature: float = 1.0 if p_model_name == "kimi-k2.5" else p_temperature
	
	var body: Dictionary = {
		"model": p_model_name,
		"messages": api_messages,
		"temperature": snappedf(final_temperature, 0.1),
		"stream": p_stream
	}
	
	if not p_tool_definitions.is_empty():
		# 直接使用 ToolRegistry 传来的标准格式，不再二次包装
		# ToolRegistry 现在返回的是 [{"type": "function", "function": ...}]
		body["tools"] = p_tool_definitions
		body["tool_choice"] = "auto"
	
	if p_stream:
		body["stream_options"] = {"include_usage": true}
	
	return body


## 解析模型列表响应
func parse_model_list_response(p_body_bytes: PackedByteArray) -> Array[String]:
	var json: Variant = JSON.parse_string(p_body_bytes.get_string_from_utf8())
	var list: Array[String] = []
	
	if json is Dictionary and json.has("data"):
		for item in json.data:
			if item.has("id"):
				list.append(item.id)
	
	return list


## 解析非流式响应 (完整 Body)
func parse_non_stream_response(p_body_bytes: PackedByteArray) -> Dictionary:
	var json: Variant = JSON.parse_string(p_body_bytes.get_string_from_utf8())
	
	if json is Dictionary and json.has("choices") and not json.choices.is_empty():
		var msg: Dictionary = json.choices[0].get("message", {})
		var result: Dictionary = {
			"content": msg.get("content", ""),
			"tool_calls": msg.get("tool_calls", []),
			"role": msg.get("role", "assistant")
		}
		
		# [修复] 解析非流式响应中的思考内容，防止数据丢失
		if msg.has("reasoning_content"):
			result["reasoning_content"] = msg.reasoning_content
			
		return result
	
	return {"error": "Unknown response format"}


## 实现流式碎片拼装逻辑
func process_stream_chunk(p_target_msg: ChatMessage, p_chunk_data: Dictionary) -> Dictionary:
	var ui_update: Dictionary = { "content_delta": "" }
	
	# 1. 提取 Usage
	if p_chunk_data.has("usage"):
		ui_update["usage"] = p_chunk_data["usage"]
	
	if not p_chunk_data.has("choices") or p_chunk_data.choices.is_empty():
		return ui_update
	
	var delta: Dictionary = p_chunk_data.choices[0].get("delta", {})
	
	# 2. 提取文本 (Text)
	if delta.has("content") and delta.content is String:
		var text: String = delta.content
		p_target_msg.content += text
		ui_update["content_delta"] = text
	
	# 3. 提取思考 (Reasoning - Kimi/DeepSeek)
	if delta.has("reasoning_content") and delta.reasoning_content is String:
		var r_text: String = delta.reasoning_content
		p_target_msg.reasoning_content += r_text
		ui_update["reasoning_delta"] = r_text
	
	# 4. 提取工具 (Tool Calls - 流式拼装)
	if delta.has("tool_calls") and delta.tool_calls is Array:
		for tc in delta.tool_calls:
			var index: int = int(tc.get("index", 0))
			
			while p_target_msg.tool_calls.size() <= index:
				p_target_msg.tool_calls.append({
					"id": "",
					"type": "function",
					"function": { "name": "", "arguments": "" }
				})
			
			var target_call: Dictionary = p_target_msg.tool_calls[index]
			
			if tc.has("id") and tc.id != null:
				target_call["id"] = tc.id
			
			if tc.has("function"):
				var f: Dictionary = tc.function
				if f.has("name") and f.name != null:
					target_call.function.name += f.name
				if f.has("arguments") and f.arguments != null:
					target_call.function.arguments += f.arguments
	
	return ui_update


# --- Private Functions ---

## 将 ChatMessage 转换为 OpenAI 格式的字典
## 统一了普通文本、多模态和工具调用的处理逻辑
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
		for img in p_msg.images:
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
		
		# [防御性修复] Tool 类型的消息内容绝对不能为空，否则会导致对话链断裂
		if p_msg.role == "tool" and final_content.is_empty():
			final_content = "SUCCESS" 
		
		# [兼容性策略] Assistant 消息如果有 ToolCall，content 必须存在
		elif p_msg.role == "assistant" and not p_msg.tool_calls.is_empty() and final_content.is_empty():
			final_content = ""
		
		dict["content"] = final_content
	
	# 3. Name 字段
	if not p_msg.name.is_empty() and p_msg.role != "tool":
		dict["name"] = p_msg.name
	
	# 4. Tool Calls
	# [防御性修复] 过滤掉可能存在的格式错误的 Tool Call (例如 id 为空的)
	if not p_msg.tool_calls.is_empty():
		var valid_calls: Array = []
		for tc in p_msg.tool_calls:
			if tc.get("id", "") != "": # 确保 id 存在
				# 确保 type 字段存在，OpenAI 规范必需
				if not tc.has("type"): tc["type"] = "function"
				valid_calls.append(tc)
		
		if not valid_calls.is_empty():
			dict["tool_calls"] = valid_calls
	
	# 5. Tool Call ID
	if not p_msg.tool_call_id.is_empty():
		dict["tool_call_id"] = p_msg.tool_call_id
	
	# [修复] 6. Reasoning Content (Kimi/DeepSeek)
	# 如果 Assistant 消息包含思考过程，必须回传，否则 API 会报错
	if p_msg.role == "assistant" and not p_msg.reasoning_content.is_empty():
		dict["reasoning_content"] = p_msg.reasoning_content
	
	return dict
