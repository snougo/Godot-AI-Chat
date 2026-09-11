@tool
class_name GeminiProvider
extends BaseLLMProvider

## Google Gemini API 的服务提供商实现


# --- Private Vars ---

## 流内工具调用序号：Gemini 的 functionCall 不携带 ID，需自行生成稳定槽位键
var _function_call_seq: int = 0


# --- Public Functions ---

## 返回该 Provider 使用的流式解析协议
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.JSON_LIST


## Gemini 原生支持将工具返回的图片直接嵌入 Tool 消息（通过 inline_data）
func supports_inline_tool_images() -> bool:
	return true


## Gemini 的 functionDeclarations 需要顶展 schema，且 type 需大写
func requires_gemini_tool_schema() -> bool:
	return true


## 重置流内状态
func reset_stream_state() -> void:
	_function_call_seq = 0


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


## [子类覆写] 构建请求体 (Body)
func build_request_body_impl(_p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, _p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	var gemini_contents: Array = []
	var system_instruction: Dictionary = {}
	
	# 1. 转换消息 (OpenAI Role -> Gemini Role)
	for msg: ChatMessage in p_messages:
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
				for raw_call: Variant in msg.tool_calls:
					if not raw_call is Dictionary:
						continue
					
					var call: Dictionary = raw_call
					var func_def: Dictionary = call.get("function", {})
					var args: Variant = JSON.parse_string(func_def.get("arguments", "{}"))
					
					var part: Dictionary = {
						"functionCall": {
							"name": func_def.get("name", ""),
							"args": args if args else {}
						}
					}
					
					# 签名附着
					var thought_signature: String = String(msg.metadata.get(ChatMessage.META_GEMINI_THOUGHT_SIGNATURE, ""))
					if not thought_signature.is_empty():
						part["thoughtSignature"] = thought_signature
					
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
			for img: Dictionary in msg.images:
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
		for item: Variant in json.models:
			if item is Dictionary and item.has("name"):
				list.append(String(item.name).replace("models/", ""))
	
	return list


## 解析非流式响应 (完整 Body)
## Gemini 的非流式与流式响应共用同一份 JSON 结构，故复用新契约后统一装配
func parse_non_stream_response(p_body_bytes: PackedByteArray) -> Dictionary:
	var json: Variant = JSON.parse_string(p_body_bytes.get_string_from_utf8())
	
	if not json is Dictionary:
		return {"error": "Invalid Gemini response"}
	
	reset_stream_state()
	var assembler: StreamMessageAssembler = StreamMessageAssembler.new()
	assembler.begin()
	assembler.apply(parse_stream_chunk(json))
	
	var msg: ChatMessage = assembler.take()
	if msg == null:
		return {"content": "", "tool_calls": [], "role": "assistant"}
	
	return {
		"content": msg.content,
		"tool_calls": msg.tool_calls,
		"role": "assistant",
		"reasoning_content": msg.reasoning_content,
	}


## 解析单个流式数据块为协议无关增量
func parse_stream_chunk(p_raw_chunk: Dictionary) -> LLMStreamDelta:
	var result: LLMStreamDelta = LLMStreamDelta.new()
	
	# 1. 提取 Usage
	var raw_meta: Variant = p_raw_chunk.get("usageMetadata")
	if raw_meta is Dictionary:
		var meta: Dictionary = raw_meta
		var prompt_tokens: int = int(meta.get("promptTokenCount", 0))
		var completion_tokens: int = int(meta.get("candidatesTokenCount", 0))
		var total_tokens: int = int(meta.get("totalTokenCount", 0))
		result.usage = {
			"prompt_tokens": prompt_tokens,
			"completion_tokens": completion_tokens,
			"total_tokens": total_tokens
		}
	
	var raw_candidates: Variant = p_raw_chunk.get("candidates")
	if not raw_candidates is Array:
		return result
	
	var candidates: Array = raw_candidates
	if candidates.is_empty():
		return result
	
	var raw_candidate: Variant = candidates[0]
	if not raw_candidate is Dictionary:
		return result
	
	var raw_content: Variant = (raw_candidate as Dictionary).get("content")
	if not raw_content is Dictionary:
		return result
	
	var raw_parts: Variant = (raw_content as Dictionary).get("parts")
	if not raw_parts is Array:
		return result
	
	for raw_part: Variant in (raw_parts as Array):
		if not raw_part is Dictionary:
			continue
		var part: Dictionary = raw_part
		
		# 2. 文本
		var raw_text: Variant = part.get("text")
		if raw_text is String and not (raw_text as String).is_empty():
			result.content_delta += raw_text
		
		# 3. 工具 (一次性完整)
		var raw_function_call: Variant = part.get("functionCall")
		if raw_function_call is Dictionary:
			var fc: Dictionary = raw_function_call
			_function_call_seq += 1
			var call_key: String = "gemini_fc_%d" % _function_call_seq
			var call_id: String = "call_%d_%d" % [Time.get_ticks_msec(), _function_call_seq]
			var tool_delta: Dictionary = LLMStreamDelta.make_tool_call_start(
				call_key,
				call_id,
				String(fc.get("name", ""))
			)
			tool_delta[LLMStreamDelta.FIELD_ARGUMENTS] = JSON.stringify(fc.get("args", {}))
			result.tool_call_deltas.append(tool_delta)
			
			# 签名
			var raw_signature: Variant = part.get("thoughtSignature")
			if raw_signature is String and not (raw_signature as String).is_empty():
				result.metadata_updates[ChatMessage.META_GEMINI_THOUGHT_SIGNATURE] = raw_signature
	
	return result
