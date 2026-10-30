class_name GeminiProvider
extends BaseLLMProvider

## Google Gemini API 的服务提供商实现


# --- Constants ---

const StreamMessageAssembler := preload("res://addons/godot_ai_chat/scripts/core/stream_message_assembler.gd")

## 可安全转 int 的浮点上限（2^53，double 能精确表示整数的边界）
## 超过该值的 float 一律保持原样，避免 int() 转换溢出
const MAX_SAFE_INT_FLOAT: float = 9007199254740992.0


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
	
	# 当前待回执的 functionCall 名称列表（来自最近一条 model 消息的 tool_calls，顺序即调用顺序）
	var pending_call_names: PackedStringArray = PackedStringArray()
	# 本批回执收集器：同一轮并行调用的全部 functionResponse 最终合并进同一个 user content
	var pending_responses: Array = []
	# 本批工具返回的图片：回执 content 之后单独成一个 content（原因见 _flush_tool_responses）
	var pending_images: Array = []
	
	# 1. 转换消息 (OpenAI Role -> Gemini Role)
	for msg: ChatMessage in p_messages:
		if msg.role == ChatMessage.ROLE_SYSTEM:
			system_instruction = {"parts": [{"text": msg.content}]}
			continue
		
		# 1.1 非 TOOL 消息：TOOL 消息必须连续，遇到其它消息即视为本批回执结束，先结算
		if msg.role != ChatMessage.ROLE_TOOL \
				and (not pending_call_names.is_empty() or not pending_responses.is_empty() or not pending_images.is_empty()):
			_flush_tool_responses(gemini_contents, pending_responses, pending_images, pending_call_names)
			pending_call_names = PackedStringArray()
		
		# 1.2 TOOL 消息：只收集，不单独成 content（原因见 _flush_tool_responses 注释）
		if msg.role == ChatMessage.ROLE_TOOL:
			pending_responses.append(_make_function_response_part(msg.name, msg.content))
			
			for img: Dictionary in msg.images:
				pending_images.append({
					"inline_data": {
						"mime_type": img.mime,
						"data": Marshalls.raw_to_base64(img.data)
					}
				})
			continue
		
		var role: String = "user"
		var parts: Array = []
		
		if msg.role == ChatMessage.ROLE_ASSISTANT:
			role = "model"
			
			if not msg.content.is_empty():
				parts.append({"text": msg.content})
			
			if not msg.tool_calls.is_empty():
				# 签名读取提到循环外：只回传给「首个 functionCall part」
				# 官方规则（Gemini 3 function calling）：
				# 1) 并行调用时只有首个 functionCall part 带签名；
				# 2) 签名必须放回它原本所在的 part —— 不要搬到其它 part，也不要复制到多个 part。
				# [备注] 以上为规则陈述，非逐条实测结论。签名缺失/错位在网关侧的表征可能是空 body 的 400（无法据此反推原因），故此处严格按规则拼装，不要凭现象改回。
				var thought_signature: String = String(msg.metadata.get(ChatMessage.META_GEMINI_THOUGHT_SIGNATURE, ""))
				var is_first_call: bool = true
				
				for raw_call: Variant in msg.tool_calls:
					if not raw_call is Dictionary:
						continue
					
					var call: Dictionary = raw_call
					var func_def: Dictionary = call.get("function", {})
					var call_name: String = String(func_def.get("name", ""))
					var args: Variant = JSON.parse_string(func_def.get("arguments", "{}"))
					
					var part: Dictionary = {
						"functionCall": {
							"name": call_name,
							"args": args if args else {}
						}
					}
					
					# 签名附着（仅首个 functionCall part）
					if is_first_call and not thought_signature.is_empty():
						part["thoughtSignature"] = thought_signature
					
					parts.append(part)
					# 登记待回执名称：回执数量与顺序都必须与这里的 functionCall 严格对齐
					pending_call_names.append(call_name)
					is_first_call = false
			
			if parts.is_empty():
				parts.append({"text": ""})
		
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
	
	# 2. 历史以 TOOL 消息结尾时，结算最后一批回执
	if not pending_call_names.is_empty() or not pending_responses.is_empty() or not pending_images.is_empty():
		_flush_tool_responses(gemini_contents, pending_responses, pending_images, pending_call_names)
	
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
			# args 数值归一化：SSE 解析后所有 JSON 数字都是 float，整数会漂移成 3.0。
			# 归一化回 int，避免工具侧对 schema 声明为 integer 的参数做严格类型校验时失败。
			tool_delta[LLMStreamDelta.FIELD_ARGUMENTS] = JSON.stringify(_normalize_json_numbers(fc.get("args", {})))
			result.tool_call_deltas.append(tool_delta)
			
			# 签名
			var raw_signature: Variant = part.get("thoughtSignature")
			if raw_signature is String and not (raw_signature as String).is_empty():
				result.metadata_updates[ChatMessage.META_GEMINI_THOUGHT_SIGNATURE] = raw_signature
	
	return result


# --- Private Functions ---

# 结算一批工具回执：把同一轮的全部 functionResponse 合并进一个 user content
#
# [为什么必须合并] Gemini 要求同一个 functionCall turn 的回执中，
# functionResponse 的 part 数量与 functionCall 的 part 数量**严格相等**。
# 旧实现「一条 TOOL 消息 = 一个 user content」，并行调用 N 个工具时会生成
# N 个各含 1 个 functionResponse 的 content，网关按 turn 校验时判定数量不符，返回：
#   "[400] Please ensure that the number of function response parts is equal to
#    the number of function call parts of the function call turn."
# 官方示例的写法是把这一轮的 function_response_parts 收齐后，一次性构造
# 单个 role="user" 的 Content —— 本方法即按此实现。
#
# [图片为什么拆出去] 同一 content 内混入 inline_data 会让该 content 的 parts 数量
# 大于 functionCall 数量，在按 parts 计数的严格校验下同样 400，
# 故工具图片放在回执 content 之后的独立 user content 中（结构仍然合法）。
#
# [数量兜底] 历史可能因取消/中断残留「回执数 ≠ 调用数」的轮次，这类历史会让
# 之后每次请求都 400。这里按 p_expected_names 对齐：不足补占位、多余丢弃；
# 前面没有 functionCall 的孤立回执降级为普通文本，避免污染函数调用链。
#
# [param p_contents]: 已构建的 Gemini contents（原地追加）
# [param p_responses]: 本批收集到的 functionResponse parts（结束后清空）
# [param p_images]: 本批收集到的 inline_data parts（结束后清空）
# [param p_expected_names]: 本批回执对应的 functionCall 名称（顺序即调用顺序）
func _flush_tool_responses(p_contents: Array, p_responses: Array, p_images: Array, p_expected_names: PackedStringArray) -> void:
	# 1. 孤立回执：前面没有 functionCall turn，不能作为 functionResponse 发出
	if p_expected_names.is_empty():
		if not p_responses.is_empty():
			var fallback_text: String = ""
			for raw_resp: Variant in p_responses:
				if not raw_resp is Dictionary:
					continue
				var resp_body: Dictionary = (raw_resp as Dictionary).get("functionResponse", {})
				var resp_content: Dictionary = resp_body.get("response", {})
				if not fallback_text.is_empty():
					fallback_text += "\n\n"
				fallback_text += "[Tool result of '%s']\n%s" % [
					String(resp_body.get("name", "")),
					String(resp_content.get("content", ""))
				]
			if not fallback_text.is_empty():
				p_contents.append({"role": "user", "parts": [{"text": fallback_text}]})
			AIChatLogger.warn("[GeminiProvider] %d orphan functionResponse part(s) converted to plain text (no matching functionCall turn)." % p_responses.size())
		
		if not p_images.is_empty():
			p_contents.append({"role": "user", "parts": p_images.duplicate()})
		
		p_responses.clear()
		p_images.clear()
		return
	
	# 2. 数量对齐：多余丢弃（保留与调用顺序对应的前 N 个）、不足补占位
	if p_responses.size() > p_expected_names.size():
		AIChatLogger.warn("[GeminiProvider] Dropped %d extra functionResponse part(s) to match %d functionCall part(s)." % [p_responses.size(), p_expected_names.size()])
		p_responses.resize(p_expected_names.size())
	elif p_responses.size() < p_expected_names.size():
		AIChatLogger.warn("[GeminiProvider] Padded %d missing functionResponse part(s) to match the functionCall turn." % (p_expected_names.size() - p_responses.size()))
		for i: int in range(p_responses.size(), p_expected_names.size()):
			p_responses.append(_make_function_response_part(p_expected_names[i], "[No result: this tool call did not produce a result.]"))
	
	# 3. 名称兜底：Gemini 按 name 与 functionCall 对应，空名会让整个回执无效
	for i: int in p_responses.size():
		var resp_part: Variant = p_responses[i]
		if not resp_part is Dictionary:
			continue
		var resp_dict: Dictionary = resp_part
		var resp_body: Dictionary = resp_dict.get("functionResponse", {})
		if String(resp_body.get("name", "")).is_empty():
			resp_body["name"] = p_expected_names[i]
			resp_dict["functionResponse"] = resp_body
	
	# 4. 本轮全部回执合并进同一个 user content（duplicate：后续 clear 不能影响已存入的内容）
	p_contents.append({"role": "user", "parts": p_responses.duplicate()})
	
	# 5. 工具图片单独成 content，追加在回执之后
	if not p_images.is_empty():
		p_contents.append({"role": "user", "parts": p_images.duplicate()})
	
	p_responses.clear()
	p_images.clear()


# 构造单个 functionResponse part
# [param p_tool_name]: 工具名（必须与对应 functionCall.name 一致）
# [param p_content]: 工具返回文本
# [return]: {"functionResponse": {"name": ..., "response": {"content": ...}}}
func _make_function_response_part(p_tool_name: String, p_content: String) -> Dictionary:
	return {
		"functionResponse": {
			"name": p_tool_name,
			"response": {
				"content": p_content
			}
		}
	}


# 递归归一化 JSON 数值：整数值的 float 转回 int
# [为什么需要] Gemini 的 args 来自 SSE 里的 JSON 解析，Godot 的 JSON 解析把数字
# 一律读成 float，于是 schema 声明为 integer 的参数会漂移成 3.0，
# 再经 JSON.stringify 回写给工具时仍是 3.0；对做严格类型校验的工具会失败。
# 这里只在「值确实是整数且在 double 安全范围内」时转 int，其余原样保留。
# [param p_value]: 待归一化的值（可为 Dictionary / Array / 标量）
# [return]: 归一化后的值（容器会重建，不复用入参）
func _normalize_json_numbers(p_value: Variant) -> Variant:
	if p_value is float:
		var float_value: float = p_value
		if absf(float_value) <= MAX_SAFE_INT_FLOAT and float_value == floorf(float_value):
			return int(float_value)
		return float_value
	
	if p_value is Array:
		var normalized_arr: Array = []
		for item: Variant in p_value:
			normalized_arr.append(_normalize_json_numbers(item))
		return normalized_arr
	
	if p_value is Dictionary:
		var normalized_dict: Dictionary = {}
		for key: Variant in p_value:
			normalized_dict[key] = _normalize_json_numbers(p_value[key])
		return normalized_dict
	
	return p_value
