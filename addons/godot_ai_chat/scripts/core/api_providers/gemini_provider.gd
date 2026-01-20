@tool
class_name GeminiProvider
extends BaseLLMProvider

## Google Gemini API 的服务提供商实现。

# --- Public Functions ---

## 返回该 Provider 使用的流式解析协议
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.JSON_LIST


## 获取 HTTP 请求头
func get_request_headers(_api_key: String, _stream: bool) -> PackedStringArray:
	# Gemini 推荐将 key 放在 header 中
	return ["Content-Type: application/json", "x-goog-api-key: %s" % _api_key]


## 获取请求的 URL
func get_request_url(_base_url: String, _model_name: String, _api_key: String, _stream: bool) -> String:
	if _model_name.is_empty():
		return _base_url.path_join("v1beta/models")
	
	var _action: String = "streamGenerateContent" if _stream else "generateContent"
	var _clean_model_name: String = _model_name.trim_prefix("models/")
	var _url: String = _base_url.path_join("v1beta/models").path_join(_clean_model_name)
	return "%s:%s" % [_url, _action]


## 构建请求体 (Body)
func build_request_body(_model_name: String, _messages: Array[ChatMessage], _temperature: float, _stream: bool, _tool_definitions: Array = []) -> Dictionary:
	# --- [添加在这里] ---
	var tool_names := []
	for tool_def in _tool_definitions:
		# Gemini 的工具定义结构可能包裹在 functionDeclarations 中，或者直接是列表
		# 根据你的实现，这里 _tool_definitions 应该是一个 function declaration 的列表
		tool_names.append(tool_def.get("name", "Unknown"))
	
	#print("[Gemini Debug] Current Model: %s" % _model_name)
	#print("[Gemini Debug] Sending Tools Count: %d" % _tool_definitions.size())
	print("[Gemini Debug] Sending Tools Names: %s" % str(tool_names))
	# ------------------
	
	var _gemini_contents: Array = []
	var _system_instruction: Dictionary = {}
	
	# 1. 转换消息 (OpenAI Role -> Gemini Role)
	for _msg in _messages:
		if _msg.role == ChatMessage.ROLE_SYSTEM:
			_system_instruction = {"parts": [{"text": _msg.content}]}
			continue
		
		var _role: String = "user"
		var _parts: Array = []
		
		if _msg.role == ChatMessage.ROLE_ASSISTANT:
			_role = "model"
			
			# 移除互斥逻辑，同时支持文本和工具
			if not _msg.content.is_empty():
				_parts.append({"text": _msg.content})
			
			if not _msg.tool_calls.is_empty():
				for _call in _msg.tool_calls:
					var _func_def: Dictionary = _call.get("function", {})
					var _args: Variant = JSON.parse_string(_func_def.get("arguments", "{}"))
					
					var _part: Dictionary = {
						"functionCall": {
							"name": _func_def.get("name", ""),
							"args": _args if _args else {}
						}
					}
					# 签名附着
					if _msg.gemini_thought_signature:
						_part["thoughtSignature"] = _msg.gemini_thought_signature
					
					_parts.append(_part)
			
			if _parts.is_empty():
				_parts.append({"text": ""})
		
		elif _msg.role == ChatMessage.ROLE_TOOL:
			_role = "function"
			_parts.append({
				"functionResponse": {
					"name": _msg.name,
					"response": {
						"content": _msg.content 
					}
				}
			})
		else:
			# User 消息
			_parts.append({"text": _msg.content})
		
		# --- 多模态图片支持 ---
		if not _msg.image_data.is_empty():
			_parts.append({
				"inline_data": {
					"mime_type": _msg.image_mime,
					"data": Marshalls.raw_to_base64(_msg.image_data)
				}
			})
		
		if not _parts.is_empty():
			_gemini_contents.append({"role": _role, "parts": _parts})
	
	var _body: Dictionary = {
		"contents": _gemini_contents,
		"generationConfig": {"temperature": _temperature},
		"safetySettings": [
			{"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_ONLY_HIGH"},
			{"category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_ONLY_HIGH"},
			{"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_ONLY_HIGH"},
			{"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_ONLY_HIGH"}
		]
	}
	
	if not _tool_definitions.is_empty():
		_body["tools"] = [{"functionDeclarations": _tool_definitions}]
	
	if not _system_instruction.is_empty():
		_body["systemInstruction"] = _system_instruction
	
	return _body


## 解析模型列表响应
func parse_model_list_response(_body_bytes: PackedByteArray) -> Array[String]:
	var _json: Variant = JSON.parse_string(_body_bytes.get_string_from_utf8())
	var _list: Array[String] = []
	
	if _json is Dictionary and _json.has("models"):
		for _item in _json.models:
			if _item.has("name"):
				_list.append(_item.name.replace("models/", ""))
	
	return _list


## 解析非流式响应 (完整 Body)
func parse_non_stream_response(_body_bytes: PackedByteArray) -> Dictionary:
	var _json: Variant = JSON.parse_string(_body_bytes.get_string_from_utf8())
	
	if _json is Dictionary:
		# 复用流式解析逻辑
		var _dummy_msg: ChatMessage = ChatMessage.new()
		process_stream_chunk(_dummy_msg, _json)
		return {
			"content": _dummy_msg.content,
			"tool_calls": _dummy_msg.tool_calls,
			"role": "assistant"
		}
	
	return {"error": "Invalid Gemini response"}


## 实现 Gemini 流式完整对象合并
# 接收原始网络数据(_chunk_data)，直接修改目标消息对象(_target_msg)的数据层
func process_stream_chunk(_target_msg: ChatMessage, _chunk_data: Dictionary) -> Dictionary:
	var _ui_update: Dictionary = { "content_delta": "" }
	
	# 1. 提取 Usage
	if _chunk_data.has("usageMetadata"):
		var _meta: Dictionary = _chunk_data.usageMetadata
		_ui_update["usage"] = {
			"prompt_tokens": _meta.get("promptTokenCount", 0),
			"completion_tokens": _meta.get("candidatesTokenCount", 0)
		}
	
	if not _chunk_data.has("candidates") or _chunk_data.candidates.is_empty():
		return _ui_update
	
	var _candidate: Dictionary = _chunk_data.candidates[0]
	var _parts: Array = _candidate.get("content", {}).get("parts", [])
	
	for _part in _parts:
		# 2. 文本
		if _part.has("text"):
			var _text: String = _part.text
			_target_msg.content += _text
			_ui_update["content_delta"] += _text
		
		# 3. 工具 (一次性完整)
		if _part.has("functionCall"):
			var _fc: Dictionary = _part.functionCall
			var _tool_call: Dictionary = {
				"id": "call_" + str(Time.get_ticks_msec()), # 生成唯一 ID
				"type": "function",
				"function": {
					"name": _fc.get("name", ""),
					"arguments": JSON.stringify(_fc.get("args", {}))
				}
			}
			
			# 移除所有去重逻辑，直接信任并添加模型返回的调用
			_target_msg.tool_calls.append(_tool_call)
			
			# 签名
			if _part.has("thoughtSignature"):
				_target_msg.gemini_thought_signature = _part.thoughtSignature
	
	return _ui_update
