@tool
extends BaseLLMProvider
class_name BaseOpenAIProvider


func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


func get_request_headers(api_key: String, stream: bool) -> PackedStringArray:
	var headers: PackedStringArray = ["Content-Type: application/json"]
	headers.append("Accept-Encoding: identity")
	
	if stream:
		headers.append("Accept: text/event-stream")
	
	if not api_key.is_empty():
		headers.append("Authorization: Bearer " + api_key)
	
	return headers


func get_request_url(base_url: String, _model_name: String, _api_key: String, _stream: bool) -> String:
	return base_url.path_join("v1/chat/completions")


func build_request_body(model_name: String, messages: Array[ChatMessage], temperature: float, stream: bool, tool_definitions: Array = []) -> Dictionary:
	var api_messages: Array[Dictionary] = []
	for msg in messages:
		api_messages.append(msg.to_api_dict())
	
	var body: Dictionary = {
		"model": model_name,
		"messages": api_messages,
		"temperature": temperature,
		"stream": stream
	}
	
	if not tool_definitions.is_empty():
		var tools_list: Array = []
		for tool_def in tool_definitions:
			tools_list.append({
				"type": "function",
				"function": tool_def
			})
		body["tools"] = tools_list
		body["tool_choice"] = "auto"
	
	if stream:
		body["stream_options"] = {"include_usage": true}
		
	return body


func parse_model_list_response(body_bytes: PackedByteArray) -> Array[String]:
	var json = JSON.parse_string(body_bytes.get_string_from_utf8())
	var list: Array[String] = []
	
	if json is Dictionary and json.has("data"):
		for item in json.data:
			if item.has("id"):
				list.append(item.id)
	
	return list


func parse_non_stream_response(body_bytes: PackedByteArray) -> Dictionary:
	var json = JSON.parse_string(body_bytes.get_string_from_utf8())
	
	if json is Dictionary and json.has("choices") and not json.choices.is_empty():
		var msg = json.choices[0].get("message", {})
		return {
			"content": msg.get("content", ""),
			"tool_calls": msg.get("tool_calls", []),
			"role": msg.get("role", "assistant")
		}
	
	return {"error": "Unknown response format"}


# [核心重构] 实现流式碎片拼装逻辑
func process_stream_chunk(target_msg: ChatMessage, chunk_data: Dictionary) -> Dictionary:
	var ui_update = { "content_delta": "" }
	
	# 1. 提取 Usage
	if chunk_data.has("usage"):
		ui_update["usage"] = chunk_data["usage"]
	
	if not chunk_data.has("choices") or chunk_data.choices.is_empty():
		return ui_update
		
	var delta = chunk_data.choices[0].get("delta", {})
	
	# 2. 提取文本 (Text)
	if delta.has("content") and delta.content is String:
		var text = delta.content
		target_msg.content += text
		ui_update["content_delta"] = text
		
	# 3. 提取思考 (Reasoning - Kimi/DeepSeek)
	if delta.has("reasoning_content") and delta.reasoning_content is String:
		var text = delta.reasoning_content
		target_msg.content += text
		ui_update["content_delta"] += text
		
	# 4. 提取工具 (Tool Calls - 流式拼装)
	if delta.has("tool_calls"):
		for tc in delta.tool_calls:
			var index = int(tc.get("index", 0))
			
			# 自动扩容数组
			while target_msg.tool_calls.size() <= index:
				target_msg.tool_calls.append({
					"id": "",
					"type": "function",
					"function": { "name": "", "arguments": "" }
				})
			
			var target_call = target_msg.tool_calls[index]
			
			# 增量合并
			if tc.has("id"):
				target_call["id"] = tc.id
			if tc.has("type"):
				target_call["type"] = tc.type
			if tc.has("function"):
				var f = tc.function
				if f.has("name"):
					target_call.function.name += f.name
				if f.has("arguments"):
					target_call.function.arguments += f.arguments
	
	return ui_update
