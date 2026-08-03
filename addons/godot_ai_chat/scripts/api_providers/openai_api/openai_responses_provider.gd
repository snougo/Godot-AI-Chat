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
				for tc in msg.tool_calls:
					var call_id: String = tc.get("id", tc.get("call_id", ""))
					var func_data: Dictionary = tc.get("function", {})
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
	
	# 1.5 推理摘要增量 (response.reasoning_summary_text.delta)
	# [修复 Bug 6] 补上缺失的 reasoning 流式事件，让思考内容实时显示
	if event_type == "response.reasoning_summary_text.delta":
		var reasoning_delta: String = p_raw_chunk.get("delta", "")
		if not reasoning_delta.is_empty():
			p_target_msg.reasoning_content += reasoning_delta
			ui_update["reasoning_delta"] = reasoning_delta
		return ui_update
	
	# 1.6 推理完整文本增量 (response.reasoning_text.delta)
	# [修复] gpt-oss 等模型使用此事件而非 reasoning_summary_text.delta
	if event_type == "response.reasoning_text.delta":
		var reasoning_delta: String = p_raw_chunk.get("delta", "")
		if not reasoning_delta.is_empty():
			p_target_msg.reasoning_content += reasoning_delta
			ui_update["reasoning_delta"] = reasoning_delta
		return ui_update
	
	# 1.7 推理摘要完成 (response.reasoning_summary_text.done) — 部分端点只发此事件
	if event_type == "response.reasoning_summary_text.done":
		var full_text: String = p_raw_chunk.get("text", "")
		var already: int = p_target_msg.reasoning_content.length()
		if full_text.length() > already:
			var new_part: String = full_text.substr(already)
			p_target_msg.reasoning_content += new_part
			ui_update["reasoning_delta"] = new_part
		return ui_update
	
	# 2. 新 Item 添加 (response.output_item.added)
	if event_type == "response.output_item.added":
		var item: Dictionary = p_raw_chunk.get("item", {})
		
		if item.get("type") == "function_call":
			var call_id: String = item.get("call_id", item.get("id", ""))
			var tool_call: Dictionary = {
				"id": call_id,
				# [修复 Bug 1] 额外保存 item.id（fc_xxx），供后续 delta/done 事件匹配
				"item_id": item.get("id", ""),
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
				# [修复 Bug 1] item_id 对应 item.id（fc_xxx），同时兼容 id（call_xxx）
				if tc.get("item_id", "") == item_id or tc.get("id", "") == item_id:
					tc.function.arguments += delta
					found = true
					break
			
			# 兜底：服务端可能省略 item_id，仍回退到最后一个（单工具调用场景）
			if not found and not p_target_msg.tool_calls.is_empty():
				p_target_msg.tool_calls[-1].function.arguments += delta
		
		return ui_update
	
	# 4. 函数调用参数完成 (response.function_call_arguments.done)
	if event_type == "response.function_call_arguments.done":
		var item_id: String = p_raw_chunk.get("item_id", "")
		var arguments: String = p_raw_chunk.get("arguments", "")
		
		if not arguments.is_empty():
			var found: bool = false
			for tc in p_target_msg.tool_calls:
				# [修复 Bug 1] 同上：匹配 item_id 或 id
				if tc.get("item_id", "") == item_id or tc.get("id", "") == item_id:
					tc.function.arguments = arguments
					found = true
					break
			
			# [修复 Bug 7] 补上与 delta 分支一致的兜底逻辑
			if not found and not p_target_msg.tool_calls.is_empty():
				p_target_msg.tool_calls[-1].function.arguments = arguments
		
		ui_update["tool_call_completed"] = true
		return ui_update
	
	# 5. 输出项完成 (response.output_item.done)
	if event_type == "response.output_item.done":
		var item: Dictionary = p_raw_chunk.get("item", {})
		
		if item.get("type") == "function_call":
			if item.has("arguments"):
				# 此分支原本就用 call_id 匹配，是正确的，保持不变
				var call_id: String = item.get("call_id", item.get("id", ""))
				for tc in p_target_msg.tool_calls:
					if tc.get("id") == call_id:
						tc.function.arguments = item.get("arguments", "")
						break
			ui_update["tool_call_completed"] = true
		
		elif item.get("type") == "reasoning":
			if item.has("summary") and item.summary is Array:
				var summary_text: String = ""
				for s in item.summary:
					if s is Dictionary and s.get("type") == "summary_text":
						summary_text += s.get("text", "")
				# 已通过流式 delta 累积的部分不重复追加
				var already: int = p_target_msg.reasoning_content.length()
				if summary_text.length() > already:
					var new_part: String = summary_text.substr(already)
					p_target_msg.reasoning_content += new_part
					ui_update["reasoning_delta"] = new_part
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
				# [修复 Bug 5] 增加类型检查，避免 summary 非数组时强转报错
				var summary: Variant = item.get("summary", [])
				if summary is Array:
					for s in summary:
						if s is Dictionary and s.get("type") == "summary_text":
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
	
	if p_json.has("usage") and p_json["usage"] is Dictionary:
		# [修复 Bug 4] 统一映射为与流式一致的内部格式
		var usage_obj: Dictionary = p_json["usage"]
		result["usage"] = {
			"prompt_tokens": usage_obj.get("input_tokens", 0),
			"completion_tokens": usage_obj.get("output_tokens", 0),
			"total_tokens": usage_obj.get("total_tokens", 0)
		}
	
	return result
