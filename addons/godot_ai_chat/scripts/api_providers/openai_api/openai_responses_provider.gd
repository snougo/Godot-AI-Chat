@tool
class_name OpenAIResponsesProvider
extends BaseOpenAIProvider

## OpenAI Responses API Provider (/v1/responses)
##
## 实现标准的 OpenAI Responses API 接口，支持:
## - instructions（系统指令）替代 system role message
## - input 字段替代 messages 数组
## - output 数组（typed Items）替代 choices 嵌套结构
## - reasoning Item 支持（GPT-5 等推理模型）


# --- Private Vars ---

## 本轮流内已产出的思考文本长度：用于对 done 事件下发的完整文本去重
var _reasoning_length: int = 0
## 本轮流内已登记的工具槽位键（按出现顺序），用于 item_id 缺失时的兜底匹配
var _tool_keys: Array[String] = []


# --- Public Functions ---

## 重置流内状态
func reset_stream_state() -> void:
	_reasoning_length = 0
	_tool_keys.clear()


## 获取请求的 URL
func get_request_url(p_base_url: String, p_model_name: String, _p_api_key: String, _p_stream: bool) -> String:
	var base: String = p_base_url.strip_edges()
	if base.ends_with("/"):
		base = base.substr(0, base.length() - 1)
	
	# 模型列表请求
	if p_model_name.is_empty():
		if base.ends_with("/responses"):
			return base.replace("/responses", "/models")
		elif base.ends_with("/v1"):
			return base + "/models"
		else:
			return base + "/v1/models"
	
	# 正常聊天请求
	if base.ends_with("/responses"):
		return base
	elif base.ends_with("/v1"):
		return base + "/responses"
	else:
		return base + "/v1/responses"


## [子类覆写] 构建请求体 (Body) — Responses API 格式
func build_request_body_impl(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	var body: Dictionary = {
		"model": p_model_name,
		"stream": p_stream,
		"temperature": snappedf(p_temperature, 0.1)
	}
	
	# 工具定义（Chat Completions 嵌套格式 → Responses API 扁平格式）
	if not p_tool_definitions.is_empty():
		var responses_tools: Array = []
		for tool: Dictionary in p_tool_definitions:
			if tool.get("type") == "function" and tool.has("function"):
				var func_data: Dictionary = tool["function"]
				responses_tools.append({
					"type": "function",
					"name": func_data.get("name", ""),
					"description": func_data.get("description", ""),
					"parameters": func_data.get("parameters", {})
				})
			else:
				responses_tools.append(tool)
		
		if not responses_tools.is_empty():
			body["tools"] = responses_tools
	
	# 提取 instructions + 构建 input 数组
	var instructions: String = ""
	var input_items: Array = []
	
	for msg: ChatMessage in p_messages:
		match msg.role:
			ChatMessage.ROLE_SYSTEM:
				if not instructions.is_empty():
					instructions += "\n\n"
				instructions += msg.content
			
			ChatMessage.ROLE_USER:
				var user_item: Dictionary = {
					"type": "message",
					"role": "user",
					"content": msg.content
				}
				# 多模态图片
				if not msg.images.is_empty():
					var content_array: Array = []
					if not msg.content.is_empty():
						content_array.append({"type": "input_text", "text": msg.content})
					for img: Dictionary in msg.images:
						var base64_str: String = Marshalls.raw_to_base64(img.data)
						var mime: String = img.get("mime", "image/png")
						content_array.append({
							"type": "input_image",
							"image_url": "data:%s;base64,%s" % [mime, base64_str]
						})
					user_item["content"] = content_array
				input_items.append(user_item)
			
			ChatMessage.ROLE_ASSISTANT:
				# [修复 Bug 3] 文本部分与工具调用部分分别回传
				# 1) 文本部分：模型调用工具前的说明文字不能丢弃
				if not msg.content.is_empty():
					input_items.append({
						"type": "message",
						"role": "assistant",
						"content": msg.content
					})
				
				# 2) 工具调用部分：每个 tool_call 回传为 function_call item
				#    （与后续 function_call_output 通过 call_id 配对，符合官方规范）
				for raw_call: Variant in msg.tool_calls:
					if not raw_call is Dictionary:
						continue
					var tc: Dictionary = raw_call
					var call_id: String = String(tc.get("id", tc.get("call_id", "")))
					var raw_func: Variant = tc.get("function", {})
					var func_data: Dictionary = raw_func if raw_func is Dictionary else {}
					input_items.append({
						"type": "function_call",
						"call_id": call_id,
						"name": func_data.get("name", ""),
						"arguments": func_data.get("arguments", "{}")
					})
			
			ChatMessage.ROLE_TOOL:
				input_items.append({
					"type": "function_call_output",
					"call_id": msg.tool_call_id,
					"output": msg.content
				})
	
	if not instructions.is_empty():
		body["instructions"] = instructions
	
	body["input"] = input_items if not input_items.is_empty() else ""
	return body


## 解析非流式响应 — Responses API 的 output 数组格式
func parse_non_stream_response(p_body_bytes: PackedByteArray) -> Dictionary:
	var json_str: String = p_body_bytes.get_string_from_utf8()
	var json: Variant = JSON.parse_string(json_str)
	
	if json is Dictionary:
		if json.has("output") and json.output is Array:
			return _parse_output_items(json)
		elif json.has("error"):
			return {"error": str(json.error), "raw": json_str}
	
	return {"error": "Unknown response format", "raw": json_str}


## 解析单个流式数据块为协议无关增量
## Responses API 使用具名事件，事件类型经传输层注入到 "_event_type" 字段
func parse_stream_chunk(p_raw_chunk: Dictionary) -> LLMStreamDelta:
	var result: LLMStreamDelta = LLMStreamDelta.new()
	var event_type: String = String(p_raw_chunk.get("_event_type", ""))
	
	# 1. 文本增量 (response.output_text.delta)
	if event_type == "response.output_text.delta":
		var delta: String = String(p_raw_chunk.get("delta", ""))
		if not delta.is_empty():
			result.content_delta = delta
		return result
	
	# 2. 推理摘要增量 (response.reasoning_summary_text.delta)
	# [修复 Bug 6] 补上缺失的 reasoning 流式事件，让思考内容实时显示
	if event_type == "response.reasoning_summary_text.delta":
		_emit_reasoning(result, String(p_raw_chunk.get("delta", "")))
		return result
	
	# 3. 推理完整文本增量 (response.reasoning_text.delta)
	# [修复] gpt-oss 等模型使用此事件而非 reasoning_summary_text.delta
	if event_type == "response.reasoning_text.delta":
		_emit_reasoning(result, String(p_raw_chunk.get("delta", "")))
		return result
	
	# 4. 推理摘要完成 (response.reasoning_summary_text.done) — 部分端点只发此事件
	if event_type == "response.reasoning_summary_text.done":
		_emit_reasoning_tail(result, String(p_raw_chunk.get("text", "")))
		return result
	
	# 5. 新 Item 添加 (response.output_item.added)
	if event_type == "response.output_item.added":
		var added_item: Dictionary = _as_dictionary(p_raw_chunk.get("item"))
		
		if added_item.get("type") == "function_call":
			var item_key: String = String(added_item.get("id", ""))
			var call_id: String = String(added_item.get("call_id", item_key))
			var call_name: String = String(added_item.get("name", ""))
			result.tool_call_deltas.append(
				LLMStreamDelta.make_tool_call_start(item_key, call_id, call_name)
			)
			if not item_key.is_empty() and not _tool_keys.has(item_key):
				_tool_keys.append(item_key)
		
		return result
	
	# 6. 函数调用参数增量 (response.function_call_arguments.delta)
	if event_type == "response.function_call_arguments.delta":
		var delta_key: String = _resolve_tool_key(String(p_raw_chunk.get("item_id", "")))
		var delta_fragment: String = String(p_raw_chunk.get("delta", ""))
		if not delta_key.is_empty() and not delta_fragment.is_empty():
			result.tool_call_deltas.append(
				LLMStreamDelta.make_tool_call_arguments_append(delta_key, delta_fragment)
			)
		return result
	
	# 7. 函数调用参数完成 (response.function_call_arguments.done)
	if event_type == "response.function_call_arguments.done":
		var done_key: String = _resolve_tool_key(String(p_raw_chunk.get("item_id", "")))
		var done_arguments: String = String(p_raw_chunk.get("arguments", ""))
		if not done_key.is_empty() and not done_arguments.is_empty():
			result.tool_call_deltas.append(
				LLMStreamDelta.make_tool_call_arguments_replace(done_key, done_arguments)
			)
		return result
	
	# 8. 输出项完成 (response.output_item.done)
	if event_type == "response.output_item.done":
		var done_item: Dictionary = _as_dictionary(p_raw_chunk.get("item"))
		
		if done_item.get("type") == "function_call":
			if done_item.has("arguments"):
				var item_key: String = _resolve_tool_key(String(done_item.get("id", "")))
				if not item_key.is_empty():
					result.tool_call_deltas.append(
						LLMStreamDelta.make_tool_call_arguments_replace(
							item_key, String(done_item.get("arguments", ""))
						)
					)
		
		elif done_item.get("type") == "reasoning":
			var raw_summary: Variant = done_item.get("summary")
			if raw_summary is Array:
				var summary_text: String = ""
				for raw_entry: Variant in (raw_summary as Array):
					if raw_entry is Dictionary and raw_entry.get("type") == "summary_text":
						summary_text += String(raw_entry.get("text", ""))
				_emit_reasoning_tail(result, summary_text)
		
		return result
	
	# 9. 响应完成 (response.completed) — 捕获 usage
	if event_type == "response.completed":
		result.is_stream_finished = true
		
		var raw_response: Variant = p_raw_chunk.get("response")
		if raw_response is Dictionary:
			var resp_obj: Dictionary = raw_response
			var raw_usage: Variant = resp_obj.get("usage")
			if raw_usage is Dictionary:
				var usage_obj: Dictionary = raw_usage
				result.usage = {
					"prompt_tokens": int(usage_obj.get("input_tokens", 0)),
					"completion_tokens": int(usage_obj.get("output_tokens", 0)),
					"total_tokens": int(usage_obj.get("total_tokens", 0))
				}
		
		return result
	
	# 10. 忽略其他中间状态事件
	return result


# --- Private Functions ---

# 追加思考增量，并同步记录本轮流内已产出的思考长度
func _emit_reasoning(p_delta: LLMStreamDelta, p_text: String) -> void:
	if p_text.is_empty():
		return
	p_delta.reasoning_delta += p_text
	_reasoning_length += p_text.length()


# 追加 done 事件下发的完整思考文本中「尚未产出的尾部」
func _emit_reasoning_tail(p_delta: LLMStreamDelta, p_full_text: String) -> void:
	if p_full_text.length() <= _reasoning_length:
		return
	_emit_reasoning(p_delta, p_full_text.substr(_reasoning_length))


# 解析工具槽位键：优先使用事件携带的 item_id；
# [修复 Bug 1 / Bug 7] 服务端可能省略 item_id，此时回退到本轮流内最后一个已登记的槽位
func _resolve_tool_key(p_raw_key: String) -> String:
	if not p_raw_key.is_empty():
		return p_raw_key
	if _tool_keys.is_empty():
		return ""
	return _tool_keys.back()


# 安全取值：非 Dictionary 时返回空字典，避免调用方反复做类型判断
func _as_dictionary(p_value: Variant) -> Dictionary:
	if p_value is Dictionary:
		return p_value
	return {}


## 解析 Responses API 的 output 数组为内部统一格式
func _parse_output_items(p_json: Dictionary) -> Dictionary:
	var content: String = ""
	var tool_calls: Array = []
	var reasoning: String = ""
	
	for raw_item: Variant in p_json.output:
		if not raw_item is Dictionary:
			continue
		var item: Dictionary = raw_item
		
		match String(item.get("type", "")):
			"message":
				var content_arr: Variant = item.get("content", [])
				if not content_arr is Array:
					continue
				for raw_block: Variant in (content_arr as Array):
					if raw_block is Dictionary and raw_block.get("type") == "output_text":
						content += String(raw_block.get("text", ""))
			
			"reasoning":
				# [修复 Bug 5] 增加类型检查，避免 summary 非数组时强转报错
				var summary: Variant = item.get("summary", [])
				if summary is Array:
					for raw_entry: Variant in (summary as Array):
						if raw_entry is Dictionary and raw_entry.get("type") == "summary_text":
							reasoning += String(raw_entry.get("text", ""))
			
			"function_call":
				tool_calls.append({
					"id": item.get("call_id", ""),
					"type": "function",
					"function": {
						"name": item.get("name", ""),
						"arguments": item.get("arguments", "")
					}
				})
	
	var result: Dictionary = {
		"content": content,
		"tool_calls": tool_calls,
		"role": "assistant"
	}
	
	if not reasoning.is_empty():
		result["reasoning_content"] = reasoning
	
	if p_json.has("usage") and p_json["usage"] is Dictionary:
		# [修复 Bug 4] 统一映射为与流式一致的内部格式
		var usage_obj: Dictionary = p_json["usage"]
		result["usage"] = {
			"prompt_tokens": usage_obj.get("input_tokens", 0),
			"completion_tokens": usage_obj.get("output_tokens", 0),
			"total_tokens": usage_obj.get("total_tokens", 0)
		}
	
	return result
