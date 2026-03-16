@tool
class_name BaseAnthropicProvider
extends BaseLLMProvider

## Anthropic 协议基类
##
## 处理 Claude 系列模型的 Message API 格式构建和 SSE 流式响应解析。

# --- Private Vars ---

var _stream_tool_index_map: Dictionary = {}
var _current_stream_usage: Dictionary = {}


# --- Public Functions ---

func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


func build_request_body(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	_stream_tool_index_map.clear()
	
	# kimi-k2.5 模型只接受固定温度值 1，强制覆盖用户设置
	if p_model_name == "kimi-k2.5":
		p_temperature = 1.0
	
	var system_prompt: String = ""
	var api_messages: Array[Dictionary] = []
	
	for msg in p_messages:
		if msg.role == "system":
			if not system_prompt.is_empty():
				system_prompt += "\n"
			system_prompt += msg.content
		else:
			api_messages.append(_convert_message_to_anthropic(msg))
	
	# 统一规范化处理：合并连续角色、清理孤立工具、移除空消息（遵循Anthropic官方的API端点设计标准）
	# 注意硅基流动等API提供商并不真正支持Anthropic API端点，其服务器内部实现是将openAI API映射成Anthropic API
	# 如果你一定要在Anthropic API下使用硅基流动的API，请将下面这条代码注释掉
	# 对于其他遵循Anthropic API端点标准的服务商，则不需要这么做
	api_messages = _normalize_anthropic_messages(api_messages)
	
	var body: Dictionary = {
		"model": p_model_name,
		"messages": api_messages,
		"temperature": snappedf(p_temperature, 0.1),
		"max_tokens": 8192, # [优化] 改为 8192，确保官方 API 不会因为上限越界而报错
		"stream": p_stream
	}
	
	if not system_prompt.is_empty():
		body["system"] = system_prompt
	
	if not p_tool_definitions.is_empty():
		var anthropic_tools: Array = []
		for tool_def in p_tool_definitions:
			anthropic_tools.append(_convert_tool_definition(tool_def))
		body["tools"] = anthropic_tools
	
	return body


func parse_non_stream_response(p_body_bytes: PackedByteArray) -> Dictionary:
	var json_str: String = p_body_bytes.get_string_from_utf8()
	var json: Variant = JSON.parse_string(json_str)
	
	if json == null:
		AIChatLogger.error("BaseAnthropicProvider: Failed to parse JSON response")
		return {"error": "Invalid JSON response", "raw": json_str.substr(0, 500)}
	
	if not json is Dictionary:
		AIChatLogger.error("BaseAnthropicProvider: Response is not a Dictionary")
		return {"error": "Unexpected response format", "raw": str(json).substr(0, 500)}
	
	if json.has("error"):
		var error_msg: String = json.error.get("message", str(json.error)) if json.error is Dictionary else str(json.error)
		AIChatLogger.error("BaseAnthropicProvider: API Error: " + error_msg)
		return {"error": error_msg, "raw": json}
	
	if json.has("content"):
		var result: Dictionary = {
			"role": json.get("role", "assistant"),
			"content": "",
			"tool_calls": []
		}
		
		if json.content is Array:
			for block in json.content:
				if not block is Dictionary:
					continue
				
				if block.get("type", "") == "text":
					result.content += block.get("text", "")
				elif block.get("type", "") == "tool_use":
					var input_data: Variant = block.get("input", {})
					var input_str: String = JSON.stringify(input_data) if input_data is Dictionary or input_data is Array else str(input_data)
					result.tool_calls.append({
						"id": block.get("id", ""),
						"type": "function",
						"function": { "name": block.get("name", ""), "arguments": input_str }
					})
		
		if json.has("usage"):
			result.usage = _normalize_usage(json.usage)
		return result
	
	return {"error": "Unknown response format", "raw": json_str.substr(0, 500)}


func process_stream_chunk(p_target_msg: ChatMessage, p_chunk_data: Dictionary) -> Dictionary:
	var ui_update: Dictionary = { "content_delta": "" }
	var type: String = p_chunk_data.get("type", "")
	var index: int = int(p_chunk_data.get("index", -1))
	
	match type:
		"message_start":
			_stream_tool_index_map.clear()
			_current_stream_usage.clear()
			if p_chunk_data.has("message") and p_chunk_data.message.has("usage"):
				_update_and_normalize_usage(p_chunk_data.message.usage)
				ui_update.usage = _current_stream_usage.duplicate()
		
		"content_block_start":
			var block_type: String = p_chunk_data.get("content_block", {}).get("type", "")
			if block_type == "tool_use":
				var block: Dictionary = p_chunk_data.content_block
				p_target_msg.tool_calls.append({
					"id": block.get("id", ""),
					"type": "function",
					"function": { "name": block.get("name", ""), "arguments": "" }
				})
				_stream_tool_index_map[index] = p_target_msg.tool_calls.size() - 1
		
		"content_block_delta":
			var delta: Dictionary = p_chunk_data.get("delta", {})
			var delta_type: String = delta.get("type", "")
			
			match delta_type:
				"text_delta":
					var text: String = delta.get("text", "")
					p_target_msg.content += text
					ui_update.content_delta = text
				"thinking_delta":
					var thinking_text: String = delta.get("thinking", "")
					if not thinking_text.is_empty():
						p_target_msg.reasoning_content += thinking_text
						ui_update["reasoning_delta"] = thinking_text
				"input_json_delta":
					var fragment: String = delta.get("partial_json", delta.get("args", delta.get("arguments", "")))
					if not fragment.is_empty():
						if _stream_tool_index_map.has(index):
							var array_idx: int = _stream_tool_index_map[index]
							if array_idx < p_target_msg.tool_calls.size():
								p_target_msg.tool_calls[array_idx].function.arguments += fragment
						elif not p_target_msg.tool_calls.is_empty():
							p_target_msg.tool_calls.back().function.arguments += fragment
		
		"message_delta":
			if p_chunk_data.has("usage"):
				_update_and_normalize_usage(p_chunk_data.usage)
				ui_update.usage = _current_stream_usage.duplicate()
		
		"message_stop":
			ui_update.stream_finished = true
	
	return ui_update


# --- Private Functions ---

# 基于状态收敛的 Anthropic 消息规范化器
# 自动合并连续角色、清除孤立工具调用、清除空消息
func _normalize_anthropic_messages(messages: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = messages.duplicate(true)
	var changed: bool = true
	
	# 如果数组发生任何合并或删除，触发重新检查，直到结构绝对稳定且完美符合要求
	while changed:
		changed = false
		
		# 1. 合并连续相同角色的消息
		var merged: Array[Dictionary] =[]
		for msg in result:
			if merged.is_empty():
				merged.append(msg)
				continue
			
			var last_msg: Dictionary = merged.back()
			if last_msg.role == msg.role:
				changed = true
				var c1: Array = last_msg.content if last_msg.content is Array else [{"type": "text", "text": last_msg.content}]
				var c2: Array = msg.content if msg.content is Array else[{"type": "text", "text": msg.content}]
				last_msg.content = c1 + c2
			else:
				merged.append(msg)
		result = merged
		
		# 2. 清理孤立的 tool_use 和 tool_result
		for i in range(result.size()):
			var msg: Dictionary = result[i]
			if not msg.content is Array: continue
			
			if msg.role == "assistant":
				var valid_ids: Dictionary = {}
				if i + 1 < result.size() and result[i+1].role == "user" and result[i+1].content is Array:
					for b in result[i+1].content:
						if b is Dictionary and b.get("type") == "tool_result":
							valid_ids[b.get("tool_use_id")] = true
				
				var new_content: Array =[]
				for b in msg.content:
					if b is Dictionary and b.get("type") == "tool_use":
						if valid_ids.has(b.get("id")):
							new_content.append(b)
						else:
							changed = true
							AIChatLogger.warn("[BaseAnthropic] Removed orphaned tool_use: " + b.get("id", ""))
					else:
						new_content.append(b)
				msg.content = new_content
			
			elif msg.role == "user":
				var valid_ids: Dictionary = {}
				if i - 1 >= 0 and result[i-1].role == "assistant" and result[i-1].content is Array:
					for b in result[i-1].content:
						if b is Dictionary and b.get("type") == "tool_use":
							valid_ids[b.get("id")] = true
				
				var new_content: Array =[]
				for b in msg.content:
					if b is Dictionary and b.get("type") == "tool_result":
						if valid_ids.has(b.get("tool_use_id")):
							new_content.append(b)
						else:
							changed = true
							AIChatLogger.warn("[BaseAnthropic] Removed orphaned tool_result: " + b.get("tool_use_id", ""))
					else:
						new_content.append(b)
				msg.content = new_content
		
		# 3. 移除空消息
		var no_empty: Array[Dictionary] =[]
		for msg in result:
			if msg.content is Array:
				if msg.content.is_empty():
					changed = true
					continue
				if msg.content.size() == 1 and msg.content[0].get("type") == "text":
					msg.content = msg.content[0].get("text", "") # 简化回纯文本
			elif msg.content is String and msg.content.is_empty():
				changed = true
				continue
			no_empty.append(msg)
		result = no_empty
	
	return result


func _update_and_normalize_usage(p_new_usage: Dictionary) -> void:
	if p_new_usage.has("input_tokens"):
		_current_stream_usage.prompt_tokens = p_new_usage.input_tokens
	if p_new_usage.has("output_tokens"):
		_current_stream_usage.completion_tokens = p_new_usage.output_tokens
	if _current_stream_usage.has("prompt_tokens") and _current_stream_usage.has("completion_tokens"):
		_current_stream_usage.total_tokens = _current_stream_usage.prompt_tokens + _current_stream_usage.completion_tokens


func _normalize_usage(p_usage: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	if p_usage.has("input_tokens"):
		result.prompt_tokens = p_usage.input_tokens
	if p_usage.has("output_tokens"):
		result.completion_tokens = p_usage.output_tokens
	if result.has("prompt_tokens") and result.has("completion_tokens"):
		result.total_tokens = result.prompt_tokens + result.completion_tokens
	return result


func _convert_tool_definition(p_openai_tool: Dictionary) -> Dictionary:
	if p_openai_tool.has("input_schema"):
		return p_openai_tool
	if p_openai_tool.has("function"):
		var func_def: Dictionary = p_openai_tool.function
		var tool: Dictionary = { "name": func_def.get("name", ""), "input_schema": func_def.get("parameters", {}) }
		if func_def.has("description"):
			tool.description = func_def.description
		return tool
	return p_openai_tool


func _convert_message_to_anthropic(p_msg: ChatMessage) -> Dictionary:
	var role: String = p_msg.role
	var content: Variant = p_msg.content
	
	if role == "tool":
		role = "user"
		content =[{ "type": "tool_result", "tool_use_id": p_msg.tool_call_id, "content": p_msg.content }]
	elif role == "user":
		content = _build_user_content(p_msg)
	elif role == "assistant":
		content = _build_assistant_content(p_msg)
	
	return { "role": role, "content": content }


func _build_user_content(p_msg: ChatMessage) -> Variant:
	var has_images: bool = false
	if not p_msg.images.is_empty():
		for img in p_msg.images:
			if img.has("data") and img.data is PackedByteArray:
				has_images = true
				break
	
	if not has_images:
		return p_msg.content
	
	var content_array: Array =[]
	for img in p_msg.images:
		if not img.has("data") or not img.data is PackedByteArray:
			continue
		
		var media_type: String = img.get("mime", "image/jpeg")
		content_array.append({
			"type": "image",
			"source": { "type": "base64", "media_type": media_type, "data": Marshalls.raw_to_base64(img.data) }
		})
	
	if not p_msg.content.is_empty():
		content_array.append({ "type": "text", "text": p_msg.content })
	
	return content_array


func _build_assistant_content(p_msg: ChatMessage) -> Variant:
	if p_msg.tool_calls.is_empty() and p_msg.reasoning_content.is_empty():
		return p_msg.content
	
	var content_array: Array = []
	if not p_msg.reasoning_content.is_empty():
		content_array.append({ "type": "thinking", "thinking": p_msg.reasoning_content })
	
	if not p_msg.content.is_empty():
		content_array.append({ "type": "text", "text": p_msg.content })
	
	for tc in p_msg.tool_calls:
		var args_obj: Dictionary = {}
		if tc.has("function") and tc.function.has("arguments"):
			var args_str: String = tc.function.arguments
			if not args_str.is_empty():
				var parsed: Variant = JSON.parse_string(args_str)
				if parsed != null and (parsed is Dictionary or parsed is Array):
					args_obj = parsed
				else:
					AIChatLogger.warn("[BaseAnthropicProvider] Invalid tool arguments JSON: " + args_str.substr(0, 200))
		
		content_array.append({
			"type": "tool_use",
			"id": tc.get("id", ""),
			"name": tc.function.get("name", ""),
			"input": args_obj
		})
	
	return content_array
