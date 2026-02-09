@tool
class_name BaseAnthropicProvider
extends BaseLLMProvider

## Anthropic 协议基类
##
## 处理 Claude 系列模型的 Message API 格式构建和 SSE 流式响应解析。
## 增强了对 SiliconFlow 等兼容性接口的鲁棒性（工具参数 Start/Delta 冲突解决）。

# --- Private Vars ---

# Key: content_block_index (int), Value: tool_calls array index (int)
var _stream_tool_index_map: Dictionary = {}

# 记录哪些 index 已经收到了 input_json_delta
# Key: content_block_index (int), Value: true
var _tool_delta_received_set: Dictionary = {}
# [新增] 成员变量用于累积 Usage
var _current_stream_usage: Dictionary = {}


# --- Public Functions ---

func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


func build_request_body(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	_stream_tool_index_map.clear()
	_tool_delta_received_set.clear()
	
	var system_prompt: String = ""
	var api_messages: Array[Dictionary] = []
	
	for msg in p_messages:
		if msg.role == "system":
			if not system_prompt.is_empty(): system_prompt += "\n"
			system_prompt += msg.content
		else:
			api_messages.append(_convert_message_to_anthropic(msg))
	
	var body: Dictionary = {
		"model": p_model_name,
		"messages": api_messages,
		"max_tokens": 4096,
		"temperature": p_temperature,
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
	var json: Variant = JSON.parse_string(p_body_bytes.get_string_from_utf8())
	
	if json is Dictionary and json.has("content"):
		var result: Dictionary = {
			"role": json.get("role", "assistant"),
			"content": "",
			"tool_calls": []
		}
		
		if json.content is Array:
			for block in json.content:
				if block.type == "text":
					result["content"] += block.text
				elif block.type == "tool_use":
					result["tool_calls"].append({
						"id": block.id,
						"type": "function",
						"function": {
							"name": block.name,
							"arguments": JSON.stringify(block.input)
						}
					})
		return result
	
	return {"error": "Unknown response format or error: " + str(json)}


func process_stream_chunk(p_target_msg: ChatMessage, p_chunk_data: Dictionary) -> Dictionary:
	var ui_update: Dictionary = { "content_delta": "" }
	var type: String = p_chunk_data.get("type", "")
	var index: int = int(p_chunk_data.get("index", -1))
	
	match type:
		"message_start":
			_stream_tool_index_map.clear()
			_tool_delta_received_set.clear()
			_current_stream_usage.clear() # 重置
			
			if p_chunk_data.has("message"):
				var msg_info: Dictionary = p_chunk_data.message
				if msg_info.has("usage"):
					# 累积并标准化
					_merge_and_normalize_usage(msg_info.usage)
					ui_update["usage"] = msg_info.usage
		
		"content_block_start":
			var block: Dictionary = p_chunk_data.get("content_block", {})
			if block.get("type") == "tool_use":
				var new_call: Dictionary = {
					"id": block.get("id", ""),
					"type": "function",
					"function": {
						"name": block.get("name", ""),
						"arguments": "" 
					}
				}
				
				# [策略优化] 读取 start 中的 input，但作为备选方案
				if block.has("input") and block.input is Dictionary:
					var json_str = JSON.stringify(block.input)
					if json_str != "{}":
						new_call.function.arguments = json_str
				
				p_target_msg.tool_calls.append(new_call)
				_stream_tool_index_map[index] = p_target_msg.tool_calls.size() - 1
		
		"content_block_delta":
			var delta: Dictionary = p_chunk_data.get("delta", {})
			var delta_type: String = delta.get("type", "")
			
			if delta_type == "text_delta":
				var text: String = delta.get("text", "")
				p_target_msg.content += text
				ui_update["content_delta"] = text
			
			elif delta_type == "input_json_delta":
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
							# [冲突解决] 如果这是第一次收到 delta，且 arguments 已经有内容（来自 start）
							# 说明 start 和 delta 重复了，我们优先信任 delta（清空 start 内容）
							if not _tool_delta_received_set.has(index):
								if not target_tool.function.arguments.is_empty():
									target_tool.function.arguments = "" # 清空旧数据
								_tool_delta_received_set[index] = true # 标记已进入 delta 模式
							
							target_tool.function.arguments += fragment
						else:
							push_warning("[BaseAnthropic] Tool array index out of bounds!")
					else:
						# Fallback
						if not p_target_msg.tool_calls.is_empty():
							p_target_msg.tool_calls.back().function.arguments += fragment
		
		"message_delta":
			if p_chunk_data.has("usage"):
				# 累积并标准化 (Output Tokens 通常在这里)
				_merge_and_normalize_usage(p_chunk_data.usage)
				ui_update["usage"] = _current_stream_usage.duplicate()
	
	return ui_update


# ----- helper function -----

# 合并并转换键名
func _merge_and_normalize_usage(p_new_usage: Dictionary) -> void:
	# Anthropic Keys -> OpenAI Keys
	if p_new_usage.has("input_tokens"):
		_current_stream_usage["prompt_tokens"] = p_new_usage.input_tokens
	if p_new_usage.has("output_tokens"):
		_current_stream_usage["completion_tokens"] = p_new_usage.output_tokens
	
	# 如果以后支持 cache_creation_input_tokens 等其他字段，也可以在这里映射


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
			tool["description"] = func_def.description
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
	
	# [修复] 多图支持
	elif role == "user" and (not p_msg.images.is_empty() or not p_msg.image_data.is_empty()):
		var content_array: Array = []
		
		# 1. 处理新版多图
		for img in p_msg.images:
			var base64_str: String = Marshalls.raw_to_base64(img.data)
			var media_type: String = img.mime
			if media_type.is_empty(): media_type = "image/jpeg"
			
			content_array.append({
				"type": "image",
				"source": {"type": "base64", "media_type": media_type, "data": base64_str}
			})
		
		# 2. 兼容旧版单图 (仅当 images 为空时)
		if p_msg.images.is_empty() and not p_msg.image_data.is_empty():
			var base64_str: String = Marshalls.raw_to_base64(p_msg.image_data)
			var media_type: String = p_msg.image_mime
			if media_type.is_empty(): media_type = "image/jpeg"
			
			content_array.append({
				"type": "image",
				"source": {"type": "base64", "media_type": media_type, "data": base64_str}
			})
		
		# 3. 追加文本
		if not p_msg.content.is_empty():
			content_array.append({ "type": "text", "text": p_msg.content })
		
		content = content_array
	
	elif role == "assistant" and not p_msg.tool_calls.is_empty():
		var content_array: Array = []
		if not p_msg.content.is_empty():
			content_array.append({ "type": "text", "text": p_msg.content })
		
		for tc in p_msg.tool_calls:
			var args_obj: Variant = {}
			if not tc.function.arguments.is_empty():
				var parsed = JSON.parse_string(tc.function.arguments)
				if parsed is Dictionary:
					args_obj = parsed
			
			content_array.append({
				"type": "tool_use",
				"id": tc.id,
				"name": tc.function.name,
				"input": args_obj
			})
		
		content = content_array
	
	return { "role": role, "content": content }
