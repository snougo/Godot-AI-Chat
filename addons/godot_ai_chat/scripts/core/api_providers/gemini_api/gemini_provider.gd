@tool
class_name GeminiProvider
extends BaseLLMProvider

## Google Gemini API 的服务提供商实现

# --- Public Functions ---

## 返回该 Provider 使用的流式解析协议
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.JSON_LIST


## 获取 HTTP 请求头
func get_request_headers(p_api_key: String, _p_stream: bool) -> PackedStringArray:
	# Gemini 推荐将 key 放在 header 中
	return ["Content-Type: application/json", "x-goog-api-key: %s" % p_api_key]


## 获取请求的 URL
func get_request_url(p_base_url: String, p_model_name: String, _p_api_key: String, p_stream: bool) -> String:
	if p_model_name.is_empty():
		return p_base_url.path_join("v1beta/models")
	
	var action: String = "streamGenerateContent" if p_stream else "generateContent"
	var clean_model_name: String = p_model_name.trim_prefix("models/")
	var url: String = p_base_url.path_join("v1beta/models").path_join(clean_model_name)
	return "%s:%s" % [url, action]


## 构建请求体 (Body)
func build_request_body(_p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, _p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	var gemini_contents: Array = []
	var system_instruction: Dictionary = {}
	
	# 1. 转换消息 (OpenAI Role -> Gemini Role)
	for msg in p_messages:
		if msg.role == ChatMessage.ROLE_SYSTEM:
			system_instruction = {"parts": [{"text": msg.content}]}
			continue
		
		var role: String = "user"
		var parts: Array = []
		
		if msg.role == ChatMessage.ROLE_ASSISTANT:
			role = "model"
			
			if not msg.content.is_empty():
				parts.append({"text": msg.content})
			
			if not msg.tool_calls.is_empty():
				for call in msg.tool_calls:
					var func_def: Dictionary = call.get("function", {})
					var args: Variant = JSON.parse_string(func_def.get("arguments", "{}"))
					
					var part: Dictionary = {
						"functionCall": {
							"name": func_def.get("name", ""),
							"args": args if args else {}
						}
					}
					# 签名附着
					if msg.gemini_thought_signature:
						part["thoughtSignature"] = msg.gemini_thought_signature
					
					parts.append(part)
			
			if parts.is_empty():
				parts.append({"text": ""})
		
		elif msg.role == ChatMessage.ROLE_TOOL:
			role = "function"
			parts.append({
				"functionResponse": {
					"name": msg.name,
					"response": {
						"content": msg.content 
					}
				}
			})
		else:
			# User 消息
			parts.append({"text": msg.content})
		
		# --- 多模态多图支持 ---
		# 新版多图数组
		if not msg.images.is_empty():
			for img in msg.images:
				parts.append({
					"inline_data": {
						"mime_type": img.mime,
						"data": Marshalls.raw_to_base64(img.data)
					}
				})
		
		if not parts.is_empty():
			gemini_contents.append({"role": role, "parts": parts})
	
	var body: Dictionary = {
		"contents": gemini_contents,
		"generationConfig": {"temperature": snappedf(p_temperature, 0.1)},
		"safetySettings": [
			{"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_ONLY_HIGH"},
			{"category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_ONLY_HIGH"},
			{"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_ONLY_HIGH"},
			{"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_ONLY_HIGH"}
		]
	}
	
	if not p_tool_definitions.is_empty():
		body["tools"] = [{"functionDeclarations": p_tool_definitions}]
	
	if not system_instruction.is_empty():
		body["systemInstruction"] = system_instruction
	
	return body


## 解析模型列表响应
func parse_model_list_response(p_body_bytes: PackedByteArray) -> Array[String]:
	var json: Variant = JSON.parse_string(p_body_bytes.get_string_from_utf8())
	var list: Array[String] = []
	
	if json is Dictionary and json.has("models"):
		for item in json.models:
			if item.has("name"):
				list.append(item.name.replace("models/", ""))
	
	return list


## 解析非流式响应 (完整 Body)
func parse_non_stream_response(p_body_bytes: PackedByteArray) -> Dictionary:
	var json: Variant = JSON.parse_string(p_body_bytes.get_string_from_utf8())
	
	if json is Dictionary:
		# 复用流式解析逻辑
		var dummy_msg: ChatMessage = ChatMessage.new()
		process_stream_chunk(dummy_msg, json)
		return {
			"content": dummy_msg.content,
			"tool_calls": dummy_msg.tool_calls,
			"role": "assistant"
		}
	
	return {"error": "Invalid Gemini response"}


## 实现 Gemini 流式完整对象合并
func process_stream_chunk(p_target_msg: ChatMessage, p_chunk_data: Dictionary) -> Dictionary:
	var ui_update: Dictionary = { "content_delta": "" }
	
	# 1. 提取 Usage
	if p_chunk_data.has("usageMetadata"):
		var meta: Dictionary = p_chunk_data.usageMetadata
		ui_update["usage"] = {
			"prompt_tokens": meta.get("promptTokenCount", 0),
			"completion_tokens": meta.get("candidatesTokenCount", 0)
		}
	
	if not p_chunk_data.has("candidates") or p_chunk_data.candidates.is_empty():
		return ui_update
	
	var candidate: Dictionary = p_chunk_data.candidates[0]
	var parts: Array = candidate.get("content", {}).get("parts", [])
	
	for part in parts:
		# 2. 文本
		if part.has("text"):
			var text: String = part.text
			p_target_msg.content += text
			ui_update["content_delta"] += text
		
		# 3. 工具 (一次性完整)
		if part.has("functionCall"):
			var fc: Dictionary = part.functionCall
			var tool_call: Dictionary = {
				"id": "call_" + str(Time.get_ticks_msec()), # 生成唯一 ID
				"type": "function",
				"function": {
					"name": fc.get("name", ""),
					"arguments": JSON.stringify(fc.get("args", {}))
				}
			}
			
			# 移除所有去重逻辑，直接信任并添加模型返回的调用
			p_target_msg.tool_calls.append(tool_call)
			
			# 签名
			if part.has("thoughtSignature"):
				p_target_msg.gemini_thought_signature = part.thoughtSignature
	
	return ui_update
