@tool
class_name LMStudioStatefulProvider
extends OpenAICompatibleProvider

## LM Studio Stateful Provider (/v1/responses)
##
## This provider uses the /v1/responses endpoint which supports stateful conversations
## AND custom tools (function calling).

# --- Constants ---

const RESPONSE_ID_META_KEY: String = "lm_studio_response_id"


# --- Public Functions ---

## 获取请求的 URL
func get_request_url(p_base_url: String, p_model_name: String, p_api_key: String, p_stream: bool) -> String:
	var base: String = p_base_url.strip_edges()
	if base.ends_with("/"):
		base = base.substr(0, base.length() - 1)
	
	if p_model_name.is_empty():
		return base + "/v1/models"
	
	return base + "/v1/responses"


## 构建请求体 (Body)
func build_request_body(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	var body: Dictionary = {
		"model": p_model_name,
		"stream": p_stream,
		"temperature": snappedf(p_temperature, 0.1)
	}
	
	# [修复] 启用工具支持 - 转换为 Responses API 格式
	if not p_tool_definitions.is_empty():
		var responses_tools: Array = []
		for tool in p_tool_definitions:
			if tool.get("type") == "function" and tool.has("function"):
				# 从 Chat Completions 格式转换为 Responses API 格式
				var func_data: Dictionary = tool["function"]
				responses_tools.append({
					"type": "function",
					"name": func_data.get("name", ""),
					"description": func_data.get("description", ""),
					"parameters": func_data.get("parameters", {})
				})
			else:
				# 已经是 Responses API 格式或未知格式，直接添加
				responses_tools.append(tool)
		
		if not responses_tools.is_empty():
			body["tools"] = responses_tools
	
	# 寻找上下文锚点
	var prev_response_id: String = ""
	for i in range(p_messages.size() - 2, -1, -1):
		var msg: ChatMessage = p_messages[i]
		if msg.role == "assistant":
			if msg.has_meta(RESPONSE_ID_META_KEY):
				prev_response_id = msg.get_meta(RESPONSE_ID_META_KEY)
				break
	
	if not prev_response_id.is_empty():
		body["previous_response_id"] = prev_response_id
	
	# 构建 Input 字段
	var input_content: String = ""
	if not p_messages.is_empty():
		var last_msg: ChatMessage = p_messages[-1]
		if last_msg.content != null:
			input_content = last_msg.content
	
	body["input"] = input_content
	
	return body


## 处理流式响应块 (适配 LM Studio /v1/responses SSE 格式)
func process_stream_chunk(p_target_msg: ChatMessage, p_raw_chunk: Dictionary) -> Dictionary:
	var ui_update: Dictionary = { "content_delta": "" }
	var event_type: String = p_raw_chunk.get("_event_type", "")
	
	# [调试] 打印工具调用相关事件
	#if event_type.begins_with("response.") and not event_type.begins_with("response.output_text"):
		#print("[DEBUG] Event: ", event_type, " Data: ", JSON.stringify(p_raw_chunk))
	
	# 1. 处理文本增量 (response.output_text.delta)
	if event_type == "response.output_text.delta":
		var delta: String = p_raw_chunk.get("delta", "")
		if not delta.is_empty():
			p_target_msg.content += delta
			ui_update["content_delta"] = delta
		return ui_update
	
	# 2. 处理工具调用 - 新的工具调用项添加
	if event_type == "response.output_item.added":
		var item: Dictionary = p_raw_chunk.get("item", {})
		if item.get("type") == "function_call":
			# [修复] 使用 call_id 而不是 id
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
			print("[LMStudio] Tool call added: ", call_id, " name: ", item.get("name", ""))
		return ui_update
	
	# 3. 处理工具调用参数增量 (response.function_call_arguments.delta)
	if event_type == "response.function_call_arguments.delta":
		var delta: String = p_raw_chunk.get("delta", "")
		var item_id: String = p_raw_chunk.get("item_id", "")
		
		if not delta.is_empty():
			# [修复] 通过 item_id 找到对应的工具调用
			var found: bool = false
			for tc in p_target_msg.tool_calls:
				if tc.get("id") == item_id:
					tc.function.arguments += delta
					found = true
					break
			
			# 如果找不到匹配的 item_id，追加到最后一个（兼容模式）
			if not found and not p_target_msg.tool_calls.is_empty():
				var last_index: int = p_target_msg.tool_calls.size() - 1
				p_target_msg.tool_calls[last_index].function.arguments += delta
		return ui_update
	
	# 4. 处理工具调用参数完成 (response.function_call_arguments.done)
	if event_type == "response.function_call_arguments.done":
		var item_id: String = p_raw_chunk.get("item_id", "")
		var arguments: String = p_raw_chunk.get("arguments", "")
		
		# [新增] 使用 done 事件中的完整参数
		if not arguments.is_empty():
			for tc in p_target_msg.tool_calls:
				if tc.get("id") == item_id:
					tc.function.arguments = arguments  # 覆盖之前的增量
					print("[LMStudio] Tool call arguments done: ", item_id, " args: ", arguments)
					break
		
		ui_update["tool_call_completed"] = true
		return ui_update
	
	# 5. 处理输出项完成 (response.output_item.done)
	if event_type == "response.output_item.done":
		var item: Dictionary = p_raw_chunk.get("item", {})
		if item.get("type") == "function_call":
			# [修复] 如果 item 中包含完整的 arguments，也更新一下
			if item.has("arguments"):
				var call_id: String = item.get("call_id", item.get("id", ""))
				for tc in p_target_msg.tool_calls:
					if tc.get("id") == call_id:
						tc.function.arguments = item.get("arguments", "")
						break
			ui_update["tool_call_completed"] = true
		return ui_update
	
	# 6. 处理结束事件，捕获 response_id (response.completed)
	if event_type == "response.completed":
		if p_raw_chunk.has("response"):
			var resp_obj: Dictionary = p_raw_chunk["response"]
			
			# 捕获 ID
			if resp_obj.has("id"):
				var rid: String = resp_obj["id"]
				p_target_msg.set_meta(RESPONSE_ID_META_KEY, rid)
			
			# 捕获 Usage
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
