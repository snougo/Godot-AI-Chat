@tool
class_name BaseAnthropicProvider
extends BaseLLMProvider

## Anthropic 协议基类
##
## 处理 Claude 系列模型的 Message API 格式构建和 SSE 流式响应解析。

# --- Private Vars ---

# Key: content_block_index (int), Value: tool_calls array index (int)
var _stream_tool_index_map: Dictionary = {}

# 累积 Usage 数据 (Key: prompt_tokens/completion_tokens, Value: int)
var _current_stream_usage: Dictionary = {}


# --- Public Functions ---

func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


func build_request_body(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	_stream_tool_index_map.clear()
	
	# --- 特殊模型处理 ---
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
	
	var body: Dictionary = {
		"model": p_model_name,
		"messages": api_messages,
		"temperature": snappedf(p_temperature, 0.1),
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
		push_error("BaseAnthropicProvider: Failed to parse JSON response")
		return {"error": "Invalid JSON response", "raw": json_str.substr(0, 500)}
	
	if not json is Dictionary:
		push_error("BaseAnthropicProvider: Response is not a Dictionary")
		return {"error": "Unexpected response format", "raw": str(json).substr(0, 500)}
	
	if json.has("error"):
		var error_msg: String = json.error.get("message", str(json.error)) if json.error is Dictionary else str(json.error)
		push_error("BaseAnthropicProvider: API Error: " + error_msg)
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
					var input_str: String
					if input_data is Dictionary or input_data is Array:
						input_str = JSON.stringify(input_data)
					else:
						input_str = str(input_data)
					
					result.tool_calls.append({
						"id": block.get("id", ""),
						"type": "function",
						"function": {
							"name": block.get("name", ""),
							"arguments": input_str
						}
					})
		
		# 处理 usage（如果存在）
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
			
			if p_chunk_data.has("message"):
				var msg_info: Dictionary = p_chunk_data.message
				if msg_info.has("usage"):
					_merge_and_normalize_usage(msg_info.usage)
					ui_update.usage = _current_stream_usage.duplicate()
		
		"content_block_start":
			var block: Dictionary = p_chunk_data.get("content_block", {})
			var block_type: String = block.get("type", "")
			
			if block_type == "tool_use":
				var new_call: Dictionary = {
					"id": block.get("id", ""),
					"type": "function",
					"function": {
						"name": block.get("name", ""),
						"arguments": ""
					}
				}
				
				# [策略变更] 忽略 start 中的 input，完全依赖后续的 input_json_delta
				# 这避免了 SiliconFlow 等平台的 Start/Delta 冲突问题
				
				p_target_msg.tool_calls.append(new_call)
				_stream_tool_index_map[index] = p_target_msg.tool_calls.size() - 1
			
			elif block_type == "thinking":
				# 思维块开始，初始化思维链内容（如果需要）
				pass
		
		"content_block_delta":
			var delta: Dictionary = p_chunk_data.get("delta", {})
			var delta_type: String = delta.get("type", "")
			
			match delta_type:
				"text_delta":
					var text: String = delta.get("text", "")
					p_target_msg.content += text
					ui_update.content_delta = text
				
				"thinking_delta":
					# 捕获思维链增量内容 (kimi-k2.5 等模型)
					var thinking_text: String = delta.get("thinking", "")
					if not thinking_text.is_empty():
						p_target_msg.reasoning_content += thinking_text
					# 思维链不直接显示在 UI 内容增量中
				
				"input_json_delta":
					var fragment: String = ""
					if delta.has("partial_json"):
						fragment = delta.partial_json
					elif delta.has("args"):
						fragment = delta.args
					elif delta.has("arguments"):
						fragment = delta.arguments
					
					if not fragment.is_empty():
						if _stream_tool_index_map.has(index):
							var array_idx: int = _stream_tool_index_map[index]
							if array_idx < p_target_msg.tool_calls.size():
								var target_tool = p_target_msg.tool_calls[array_idx]
								target_tool.function.arguments += fragment
							else:
								push_warning("[BaseAnthropic] Tool array index out of bounds: %d (size: %d)" % [array_idx, p_target_msg.tool_calls.size()])
						else:
							# Fallback: 如果未映射，尝试追加到最后一个工具
							if not p_target_msg.tool_calls.is_empty():
								p_target_msg.tool_calls.back().function.arguments += fragment
		
		"message_delta":
			if p_chunk_data.has("usage"):
				_merge_and_normalize_usage(p_chunk_data.usage)
				ui_update.usage = _current_stream_usage.duplicate()
		
		"message_stop":
			# 流式结束，可在此触发最终回调或清理
			ui_update.stream_finished = true
	
	return ui_update


# ----- Helper Functions -----

# 合并并转换键名 (Anthropic -> OpenAI 格式)
func _merge_and_normalize_usage(p_new_usage: Dictionary) -> void:
	if p_new_usage.has("input_tokens"):
		_current_stream_usage.prompt_tokens = p_new_usage.input_tokens
	if p_new_usage.has("output_tokens"):
		_current_stream_usage.completion_tokens = p_new_usage.output_tokens


# 单次转换 usage 格式（用于非流式响应）
func _normalize_usage(p_usage: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	if p_usage.has("input_tokens"):
		result.prompt_tokens = p_usage.input_tokens
	if p_usage.has("output_tokens"):
		result.completion_tokens = p_usage.output_tokens
	return result


func _convert_tool_definition(p_openai_tool: Dictionary) -> Dictionary:
	if p_openai_tool.has("input_schema"):
		return p_openai_tool
	
	if p_openai_tool.has("function"):
		var func_def: Dictionary = p_openai_tool.function
		var tool: Dictionary = {
			"name": func_def.get("name", ""),
			"input_schema": func_def.get("parameters", {})
		}
		
		if func_def.has("description"):
			tool.description = func_def.description
		return tool
	
	return p_openai_tool


func _convert_message_to_anthropic(p_msg: ChatMessage) -> Dictionary:
	var role: String = p_msg.role
	var content: Variant = p_msg.content
	
	if role == "tool":
		role = "user"
		content = [{
			"type": "tool_result",
			"tool_use_id": p_msg.tool_call_id,
			"content": p_msg.content
		}]
	
	elif role == "user":
		content = _build_user_content(p_msg)
	
	elif role == "assistant":
		content = _build_assistant_content(p_msg)
	
	return { "role": role, "content": content }


# 构建用户消息内容（支持文本和多图）
func _build_user_content(p_msg: ChatMessage) -> Variant:
	var has_images: bool = false
	
	# 检查是否有有效图片数据
	if not p_msg.images.is_empty():
		for img in p_msg.images:
			if img.has("data") and img.data is PackedByteArray:
				has_images = true
				break
	
	if not has_images:
		return p_msg.content  # 纯文本，直接返回字符串
	
	# 多模态内容（图文混合）
	var content_array: Array = []
	
	# 1. 处理新版多图数组（img 是 Dictionary）
	for img in p_msg.images:
		if not img.has("data") or not img.data is PackedByteArray:
			push_warning("BaseAnthropicProvider: Image item missing valid data field")
			continue
		
		var base64_str: String = Marshalls.raw_to_base64(img.data)
		# Dictionary.get() 支持默认值参数
		var media_type: String = img.get("mime", "")
		if media_type.is_empty(): 
			media_type = "image/jpeg"
		
		content_array.append({
			"type": "image",
			"source": {
				"type": "base64",
				"media_type": media_type,
				"data": base64_str
			}
		})
	
	# 2. 追加文本（如果有）
	if not p_msg.content.is_empty():
		content_array.append({ "type": "text", "text": p_msg.content })
	
	return content_array


# 构建助手消息内容（支持文本、思维链和工具调用）
func _build_assistant_content(p_msg: ChatMessage) -> Variant:
	# 如果没有工具调用且没有思维链内容，直接返回字符串
	if p_msg.tool_calls.is_empty() and p_msg.reasoning_content.is_empty():
		return p_msg.content
	
	var content_array: Array = []
	
	# 1. 添加思维链内容（如果存在）- kimi-k2.5 等模型需要
	if not p_msg.reasoning_content.is_empty():
		# Anthropic 格式使用 thinking 类型块
		content_array.append({
			"type": "thinking",
			"thinking": p_msg.reasoning_content
		})
	
	# 2. 添加文本内容（如果存在）
	if not p_msg.content.is_empty():
		content_array.append({ "type": "text", "text": p_msg.content })
	
	# 3. 添加工具调用（如果存在）
	for tc in p_msg.tool_calls:
		var args_obj: Dictionary = {}
		if tc.has("function") and tc.function.has("arguments"):
			var args_str: String = tc.function.arguments
			if not args_str.is_empty():
				var parsed: Variant = JSON.parse_string(args_str)
				if parsed != null and (parsed is Dictionary or parsed is Array):
					args_obj = parsed
				else:
					push_warning("BaseAnthropicProvider: Invalid tool arguments JSON: " + args_str.substr(0, 200))
		
		content_array.append({
			"type": "tool_use",
			"id": tc.get("id", ""),
			"name": tc.function.get("name", ""),
			"input": args_obj
		})
	
	return content_array
