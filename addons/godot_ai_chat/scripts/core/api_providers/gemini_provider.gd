@tool
extends BaseLLMProvider
class_name GeminiProvider


func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.JSON_LIST


func get_request_headers(api_key: String, stream: bool) -> PackedStringArray:
	# Gemini 推荐将 key 放在 header 中
	return ["Content-Type: application/json", "x-goog-api-key: %s" % api_key]


func get_request_url(base_url: String, model_name: String, api_key: String, stream: bool) -> String:
	if model_name.is_empty():
		return base_url.path_join("v1beta/models")
		
	var action: String = "streamGenerateContent" if stream else "generateContent"
	var clean_model_name = model_name.trim_prefix("models/")
	var url = base_url.path_join("v1beta/models").path_join(clean_model_name)
	return "%s:%s" % [url, action]


func build_request_body(model_name: String, messages: Array[ChatMessage], temperature: float, stream: bool, tool_definitions: Array = []) -> Dictionary:
	var gemini_contents: Array = []
	var system_instruction: Dictionary = {}
	
	# 1. 转换消息 (OpenAI Role -> Gemini Role)
	for msg in messages:
		if msg.role == ChatMessage.ROLE_SYSTEM:
			system_instruction = {"parts": [{"text": msg.content}]}
			continue
		
		var role = "user"
		var parts = []
		
		if msg.role == ChatMessage.ROLE_ASSISTANT:
			role = "model"
			
			# [架构修复] 移除互斥逻辑，同时支持文本和工具
			if not msg.content.is_empty():
				parts.append({"text": msg.content})
			
			if not msg.tool_calls.is_empty():
				for call in msg.tool_calls:
					var func_def = call.get("function", {})
					var args = JSON.parse_string(func_def.get("arguments", "{}"))
					
					var part = {
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
			parts.append({"text": msg.content})
		
		if not parts.is_empty():
			gemini_contents.append({"role": role, "parts": parts})
	
	var body = {
		"contents": gemini_contents,
		"generationConfig": {"temperature": temperature},
		"safetySettings": [
			{"category": "HARM_CATEGORY_HARASSMENT", "threshold": "BLOCK_ONLY_HIGH"},
			{"category": "HARM_CATEGORY_HATE_SPEECH", "threshold": "BLOCK_ONLY_HIGH"},
			{"category": "HARM_CATEGORY_SEXUALLY_EXPLICIT", "threshold": "BLOCK_ONLY_HIGH"},
			{"category": "HARM_CATEGORY_DANGEROUS_CONTENT", "threshold": "BLOCK_ONLY_HIGH"}
		]
	}
	
	if not tool_definitions.is_empty():
		body["tools"] = [{"functionDeclarations": tool_definitions}]
	
	if not system_instruction.is_empty():
		body["systemInstruction"] = system_instruction
	
	return body


func parse_model_list_response(body_bytes: PackedByteArray) -> Array[String]:
	var json = JSON.parse_string(body_bytes.get_string_from_utf8())
	var list: Array[String] = []
	
	if json is Dictionary and json.has("models"):
		for item in json.models:
			if item.has("name"):
				list.append(item.name.replace("models/", ""))
	
	return list


func parse_non_stream_response(body_bytes: PackedByteArray) -> Dictionary:
	var json = JSON.parse_string(body_bytes.get_string_from_utf8())
	
	if json is Dictionary:
		# 复用流式解析逻辑
		var dummy_msg = ChatMessage.new()
		process_stream_chunk(dummy_msg, json)
		return {
			"content": dummy_msg.content,
			"tool_calls": dummy_msg.tool_calls,
			"role": "assistant"
		}
	
	return {"error": "Invalid Gemini response"}


# [核心重构] 实现 Gemini 流式完整对象合并
func process_stream_chunk(target_msg: ChatMessage, chunk_data: Dictionary) -> Dictionary:
	var ui_update = { "content_delta": "" }
	
	# 1. 提取 Usage
	if chunk_data.has("usageMetadata"):
		var meta = chunk_data.usageMetadata
		ui_update["usage"] = {
			"prompt_tokens": meta.get("promptTokenCount", 0),
			"completion_tokens": meta.get("candidatesTokenCount", 0)
		}
	
	if not chunk_data.has("candidates") or chunk_data.candidates.is_empty():
		return ui_update
		
	var candidate = chunk_data.candidates[0]
	var parts = candidate.get("content", {}).get("parts", [])
	
	for part in parts:
		# 2. 文本
		if part.has("text"):
			var text = part.text
			target_msg.content += text
			ui_update["content_delta"] += text
			
		# 3. 工具 (一次性完整)
		if part.has("functionCall"):
			var fc = part.functionCall
			var tool_call = {
				"id": "call_" + str(Time.get_ticks_msec()), # 伪造 ID
				"type": "function",
				"function": {
					"name": fc.get("name", ""),
					"arguments": JSON.stringify(fc.get("args", {}))
				}
			}
			
			# 简单的查重 (防止 Gemini 流发多次相同的 call)
			var exists = false
			for ex in target_msg.tool_calls:
				if ex.function.name == tool_call.function.name and ex.function.arguments == tool_call.function.arguments:
					exists = true
					break
			
			if not exists:
				target_msg.tool_calls.append(tool_call)
			
			# 签名
			if part.has("thoughtSignature"):
				target_msg.gemini_thought_signature = part.thoughtSignature
				
	return ui_update
