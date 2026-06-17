@tool
class_name OpenAIResponsesProvider
extends BaseOpenAIProvider

## OpenAI Responses API Provider (/v1/responses)
##
## 实现标准的 OpenAI Responses API 接口，支持:
## - instructions（系统指令）替代 system role message
## - input 字段替代 messages 数组
## - previous_response_id 自动状态管理
## - output 数组（typed Items）替代 choices 嵌套结构
## - reasoning Item 支持（GPT-5 等推理模型）

# --- Constants ---

const RESPONSE_ID_META_KEY: String = "openai_response_id"


# --- Public Functions ---

## 获取请求的 URL
func get_request_url(p_base_url: String, p_model_name: String, _p_api_key: String, _p_stream: bool) -> String:
	var base: String = p_base_url.strip_edges()
	if base.ends_with("/"):
		base = base.substr(0, base.length() - 1)
	
	if p_model_name.is_empty():
		return base + "/v1/models"
	
	return base + "/v1/responses"


## 构建请求体 (Body) — Responses API 格式
func build_request_body(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	var body: Dictionary = {
		"model": p_model_name,
		"stream": p_stream,
		"temperature": snappedf(p_temperature, 0.1)
	}

	# 工具定义（Chat Completions 嵌套格式 → Responses API 扁平格式）
	if not p_tool_definitions.is_empty():
		var responses_tools: Array = []
		for tool in p_tool_definitions:
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

	for msg in p_messages:
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
					for img in msg.images:
						var base64_str: String = Marshalls.raw_to_base64(img.data)
						var mime: String = img.get("mime", "image/png")
						content_array.append({
							"type": "input_image",
							"image_url": "data:%s;base64,%s" % [mime, base64_str]
						})
					user_item["content"] = content_array
				input_items.append(user_item)

			ChatMessage.ROLE_ASSISTANT:
				# 只添加纯文本助手消息（工具调用结果由 function_call_output 表示）
				if msg.tool_calls.is_empty() and not msg.content.is_empty():
					input_items.append({
						"type": "message",
						"role": "assistant",
						"content": msg.content
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


## 处理流式响应块 — Responses API SSE 事件格式
func process_stream_chunk(p_target_msg: ChatMessage, p_raw_chunk: Dictionary) -> Dictionary:
	var ui_update: Dictionary = { "content_delta": "" }
	var event_type: String = p_raw_chunk.get("_event_type", "")
	
	# 1. 文本增量 (response.output_text.delta)
	if event_type == "response.output_text.delta":
		var delta: String = p_raw_chunk.get("delta", "")
		if not delta.is_empty():
			p_target_msg.content += delta
			ui_update["content_delta"] = delta
		return ui_update
	
	# 2. 新 Item 添加 (response.output_item.added)
	if event_type == "response.output_item.added":
		var item: Dictionary = p_raw_chunk.get("item", {})
		
		if item.get("type") == "function_call":
			var call_id: String = item.get("call_id", item.get("id", ""))
			var tool_call: Dictionary = {
				"id": call_id,
				"type": "function",
				"function": {
					"name": item.get("name", ""),
					"arguments": ""
				}
			}
			p_target_msg.tool_calls.append(tool_call)
			ui_update["tool_call_started"] = true
		
		elif item.get("type") == "reasoning":
			ui_update["reasoning_started"] = true
		
		return ui_update
	
	# 3. 函数调用参数增量 (response.function_call_arguments.delta)
	if event_type == "response.function_call_arguments.delta":
		var delta: String = p_raw_chunk.get("delta", "")
		var item_id: String = p_raw_chunk.get("item_id", "")
		
		if not delta.is_empty():
			var found: bool = false
			for tc in p_target_msg.tool_calls:
				if tc.get("id") == item_id:
					tc.function.arguments += delta
					found = true
					break
			
			if not found and not p_target_msg.tool_calls.is_empty():
				p_target_msg.tool_calls[-1].function.arguments += delta
		
		return ui_update
	
	# 4. 函数调用参数完成 (response.function_call_arguments.done)
	if event_type == "response.function_call_arguments.done":
		var item_id: String = p_raw_chunk.get("item_id", "")
		var arguments: String = p_raw_chunk.get("arguments", "")
		
		if not arguments.is_empty():
			for tc in p_target_msg.tool_calls:
				if tc.get("id") == item_id:
					tc.function.arguments = arguments
					break
		
		ui_update["tool_call_completed"] = true
		return ui_update
	
	# 5. 输出项完成 (response.output_item.done)
	if event_type == "response.output_item.done":
		var item: Dictionary = p_raw_chunk.get("item", {})
		
		if item.get("type") == "function_call":
			if item.has("arguments"):
				var call_id: String = item.get("call_id", item.get("id", ""))
				for tc in p_target_msg.tool_calls:
					if tc.get("id") == call_id:
						tc.function.arguments = item.get("arguments", "")
						break
			ui_update["tool_call_completed"] = true
		
		elif item.get("type") == "reasoning":
			if item.has("summary") and item.summary is Array:
				for s in item.summary:
					if s.get("type") == "summary_text":
						p_target_msg.reasoning_content += s.get("text", "")
			ui_update["reasoning_completed"] = true
		
		return ui_update
	
	# 6. 响应完成 (response.completed) — 捕获 response_id 和 usage
	if event_type == "response.completed":
		if p_raw_chunk.has("response"):
			var resp_obj: Dictionary = p_raw_chunk["response"]
			
			if resp_obj.has("id"):
				p_target_msg.set_meta(RESPONSE_ID_META_KEY, resp_obj["id"])
			
			if resp_obj.has("usage"):
				var usage_obj: Dictionary = resp_obj["usage"]
				ui_update["usage"] = {
					"prompt_tokens": usage_obj.get("input_tokens", 0),
					"completion_tokens": usage_obj.get("output_tokens", 0),
					"total_tokens": usage_obj.get("total_tokens", 0)
				}
		
		return ui_update
	
	# 7. 忽略其他中间状态事件
	return ui_update


# --- Private Functions ---

## 解析 Responses API 的 output 数组为内部统一格式
func _parse_output_items(p_json: Dictionary) -> Dictionary:
	var content: String = ""
	var tool_calls: Array = []
	var reasoning: String = ""
	
	for item in p_json.output:
		match item.get("type", ""):
			"message":
				var content_arr: Array = item.get("content", [])
				for block in content_arr:
					if block.get("type") == "output_text":
						content += block.get("text", "")
			"reasoning":
				var summary_arr: Array = item.get("summary", [])
				for s in summary_arr:
					if s.get("type") == "summary_text":
						reasoning += s.get("text", "")
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
	
	if p_json.has("id"):
		result["response_id"] = p_json["id"]
	
	if p_json.has("usage"):
		result["usage"] = p_json["usage"]
	
	return result
