@tool
class_name BaseOpenAIProvider
extends BaseLLMProvider

## OpenAI 兼容接口的基类实现。


# --- Public Functions ---

## 返回该 Provider 使用的流式解析协议
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


## 获取 HTTP 请求头
func get_request_headers(_api_key: String, _stream: bool) -> PackedStringArray:
	var _headers: PackedStringArray = ["Content-Type: application/json"]
	_headers.append("Accept-Encoding: identity")
	
	if _stream:
		_headers.append("Accept: text/event-stream")
	
	if not _api_key.is_empty():
		_headers.append("Authorization: Bearer " + _api_key)
	
	return _headers


## 获取请求的 URL
func get_request_url(_base_url: String, _model_name: String, _api_key: String, _stream: bool) -> String:
	return _base_url.path_join("v1/chat/completions")


## 构建请求体 (Body)
func build_request_body(_model_name: String, _messages: Array[ChatMessage], _temperature: float, _stream: bool, _tool_definitions: Array = []) -> Dictionary:
	#print("[OpenAI Debug] Current Model: %s" % _model_name)
	#print("[OpenAI Debug] Sending Tools Count: %d" % _tool_definitions.size())
	
	var _api_messages: Array[Dictionary] = []
	
	for _msg in _messages:
		# [Refactor] 核心改动：调用内部函数进行转换
		var _msg_dict: Dictionary = _convert_message_to_api_format(_msg)
		_api_messages.append(_msg_dict)
	
	var _body: Dictionary = {
		"model": _model_name,
		"messages": _api_messages,
		"temperature": _temperature,
		"stream": _stream
	}
	
	if not _tool_definitions.is_empty():
		var _tools_list: Array = []
		for _tool_def in _tool_definitions:
			_tools_list.append({
				"type": "function",
				"function": _tool_def
			})
		_body["tools"] = _tools_list
		_body["tool_choice"] = "auto"
	
	if _stream:
		_body["stream_options"] = {"include_usage": true}
	
	return _body


## 解析模型列表响应
func parse_model_list_response(_body_bytes: PackedByteArray) -> Array[String]:
	var _json: Variant = JSON.parse_string(_body_bytes.get_string_from_utf8())
	var _list: Array[String] = []
	
	if _json is Dictionary and _json.has("data"):
		for _item in _json.data:
			if _item.has("id"):
				_list.append(_item.id)
	
	return _list


## 解析非流式响应 (完整 Body)
func parse_non_stream_response(_body_bytes: PackedByteArray) -> Dictionary:
	var _json: Variant = JSON.parse_string(_body_bytes.get_string_from_utf8())
	
	if _json is Dictionary and _json.has("choices") and not _json.choices.is_empty():
		var _msg: Dictionary = _json.choices[0].get("message", {})
		return {
			"content": _msg.get("content", ""),
			"tool_calls": _msg.get("tool_calls", []),
			"role": _msg.get("role", "assistant")
		}
	
	return {"error": "Unknown response format"}


## 实现流式碎片拼装逻辑
func process_stream_chunk(_target_msg: ChatMessage, _chunk_data: Dictionary) -> Dictionary:
	var _ui_update: Dictionary = { "content_delta": "" }
	
	# 1. 提取 Usage
	if _chunk_data.has("usage"):
		_ui_update["usage"] = _chunk_data["usage"]
	
	if not _chunk_data.has("choices") or _chunk_data.choices.is_empty():
		return _ui_update
	
	var _delta: Dictionary = _chunk_data.choices[0].get("delta", {})
	
	# 2. 提取文本 (Text)
	if _delta.has("content") and _delta.content is String:
		var _text: String = _delta.content
		_target_msg.content += _text
		_ui_update["content_delta"] = _text
	
	# 3. 提取思考 (Reasoning - Kimi/DeepSeek)
	if _delta.has("reasoning_content") and _delta.reasoning_content is String:
		var _r_text: String = _delta.reasoning_content
		_target_msg.reasoning_content += _r_text
		_ui_update["reasoning_delta"] = _r_text
	
	# 4. 提取工具 (Tool Calls - 流式拼装)
	if _delta.has("tool_calls") and _delta.tool_calls is Array:
		for _tc in _delta.tool_calls:
			var _index: int = int(_tc.get("index", 0))
			
			while _target_msg.tool_calls.size() <= _index:
				_target_msg.tool_calls.append({
					"id": "",
					"type": "function",
					"function": { "name": "", "arguments": "" }
				})
			
			var _target_call: Dictionary = _target_msg.tool_calls[_index]
			
			if _tc.has("id") and _tc.id != null:
				_target_call["id"] = _tc.id
			
			if _tc.has("function"):
				var _f: Dictionary = _tc.function
				if _f.has("name") and _f.name != null:
					_target_call.function.name += _f.name
				if _f.has("arguments") and _f.arguments != null:
					_target_call.function.arguments += _f.arguments
	
	return _ui_update


# --- Private Helper ---

## [Refactor] 将 ChatMessage 转换为 OpenAI 格式的字典
## 统一了普通文本、多模态和工具调用的处理逻辑
func _convert_message_to_api_format(_msg: ChatMessage) -> Dictionary:
	var _dict: Dictionary = { "role": _msg.role }
	
	# 1. 优先处理多模态 (仅 User 且有图)
	if _msg.role == "user" and not _msg.image_data.is_empty():
		var _content_array: Array = []
		if not _msg.content.is_empty():
			_content_array.append({ "type": "text", "text": _msg.content })
		
		var _base64_str: String = Marshalls.raw_to_base64(_msg.image_data)
		_content_array.append({
			"type": "image_url",
			"image_url": { "url": "data:%s;base64,%s" % [_msg.image_mime, _base64_str] }
		})
		_dict["content"] = _content_array
	
	# 2. 普通文本处理
	else:
		var _final_content = _msg.content
		
		# [防御性修复] Tool 类型的消息内容绝对不能为空，否则会导致对话链断裂
		if _msg.role == "tool" and _final_content.is_empty():
			_final_content = "SUCCESS" # 或 "{}"，给一个占位符防止被后端丢弃
		
		# [兼容性策略] Assistant 消息如果有 ToolCall，content 必须存在
		elif _msg.role == "assistant" and not _msg.tool_calls.is_empty() and _final_content.is_empty():
			_final_content = ""
		
		_dict["content"] = _final_content
	
	# 3. Name 字段
	if not _msg.name.is_empty() and _msg.role != "tool":
		_dict["name"] = _msg.name
	
	# 4. Tool Calls
	# [防御性修复] 过滤掉可能存在的格式错误的 Tool Call (例如 id 为空的)
	if not _msg.tool_calls.is_empty():
		var _valid_calls: Array = []
		for _tc in _msg.tool_calls:
			if _tc.get("id", "") != "": # 确保 id 存在
				# 确保 type 字段存在，OpenAI 规范必需
				if not _tc.has("type"): _tc["type"] = "function"
				_valid_calls.append(_tc)
		
		if not _valid_calls.is_empty():
			_dict["tool_calls"] = _valid_calls
	
	# 5. Tool Call ID
	if not _msg.tool_call_id.is_empty():
		_dict["tool_call_id"] = _msg.tool_call_id
	
	return _dict
