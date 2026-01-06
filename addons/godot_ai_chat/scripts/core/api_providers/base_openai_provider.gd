@tool
extends BaseLLMProvider
class_name BaseOpenAIProvider


func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


func get_request_headers(_api_key: String, _stream: bool) -> PackedStringArray:
	var headers: PackedStringArray = ["Content-Type: application/json"]
	headers.append("Accept-Encoding: identity")
	
	if _stream:
		headers.append("Accept: text/event-stream")
	
	if not _api_key.is_empty():
		headers.append("Authorization: Bearer " + _api_key)
	
	return headers


func get_request_url(_base_url: String, _model_name: String, _api_key: String, _stream: bool) -> String:
	return _base_url.path_join("v1/chat/completions")


func build_request_body(_model_name: String, _messages: Array[ChatMessage], _temperature: float, _stream: bool, _tool_definitions: Array = []) -> Dictionary:
	var api_messages: Array[Dictionary] = []
	
	for msg in _messages:
		var msg_dict: Dictionary = msg.to_api_dict()
		
		# --- 多模态图片支持 ---
		if not msg.image_data.is_empty():
			var content_array = []
			
			# 1. 如果有文本内容，添加为 text 类型块
			if not msg.content.is_empty():
				content_array.append({
					"type": "text",
					"text": msg.content
				})
			
			# 2. 添加图片块 (使用 Data URL 格式)
			var base64_str = Marshalls.raw_to_base64(msg.image_data)
			content_array.append({
				"type": "image_url",
				"image_url": {
					"url": "data:%s;base64,%s" % [msg.image_mime, base64_str]
				}
			})
			
			# 覆盖原有的 String content
			msg_dict["content"] = content_array
		
		api_messages.append(msg_dict)
	
	var body: Dictionary = {
		"model": _model_name,
		"messages": api_messages,
		"temperature": _temperature,
		"stream": _stream
	}
	
	if not _tool_definitions.is_empty():
		var tools_list: Array = []
		for tool_def in _tool_definitions:
			tools_list.append({
				"type": "function",
				"function": tool_def
			})
		body["tools"] = tools_list
		body["tool_choice"] = "auto"
	
	if _stream:
		body["stream_options"] = {"include_usage": true}
	
	return body



func parse_model_list_response(_body_bytes: PackedByteArray) -> Array[String]:
	var json = JSON.parse_string(_body_bytes.get_string_from_utf8())
	var list: Array[String] = []
	
	if json is Dictionary and json.has("data"):
		for item in json.data:
			if item.has("id"):
				list.append(item.id)
	
	return list


func parse_non_stream_response(_body_bytes: PackedByteArray) -> Dictionary:
	var json = JSON.parse_string(_body_bytes.get_string_from_utf8())
	
	if json is Dictionary and json.has("choices") and not json.choices.is_empty():
		var msg = json.choices[0].get("message", {})
		return {
			"content": msg.get("content", ""),
			"tool_calls": msg.get("tool_calls", []),
			"role": msg.get("role", "assistant")
		}
	
	return {"error": "Unknown response format"}


# [核心重构] 实现流式碎片拼装逻辑
func process_stream_chunk(_target_msg: ChatMessage, _chunk_data: Dictionary) -> Dictionary:
	var ui_update = { "content_delta": "" }
	
	# 1. 提取 Usage
	if _chunk_data.has("usage"):
		ui_update["usage"] = _chunk_data["usage"]
	
	if not _chunk_data.has("choices") or _chunk_data.choices.is_empty():
		return ui_update
	
	var delta = _chunk_data.choices[0].get("delta", {})
	
	# 2. 提取文本 (Text)
	if delta.has("content") and delta.content is String:
		var text = delta.content
		_target_msg.content += text
		ui_update["content_delta"] = text
	
	# 3. 提取思考 (Reasoning - Kimi/DeepSeek)
	if delta.has("reasoning_content") and delta.reasoning_content is String:
		var text = delta.reasoning_content
		_target_msg.content += text
		ui_update["content_delta"] += text
	
	# 4. 提取工具 (Tool Calls - 流式拼装)
	# [修复] 增加对 delta.tool_calls 是否为 null 的检查
	if delta.has("tool_calls") and delta.tool_calls is Array:
		for tc in delta.tool_calls:
			var index = int(tc.get("index", 0))
			
			# 自动扩容数组
			while _target_msg.tool_calls.size() <= index:
				_target_msg.tool_calls.append({
					"id": "",
					"type": "function",
					"function": { "name": "", "arguments": "" }
				})
			
			var target_call = _target_msg.tool_calls[index]
			
			# 增量合并
			if tc.has("id") and tc.id != null:
				target_call["id"] = tc.id
			
			if tc.has("function"):
				var f = tc.function
				if f.has("name") and f.name != null:
					target_call.function.name += f.name
				if f.has("arguments") and f.arguments != null:
					target_call.function.arguments += f.arguments # 确保此处累加的是有效的字符串
	
	return ui_update
