@tool
class_name LMStudioStatefulProvider
extends OpenAICompatibleProvider

## LM Studio Stateful Provider (/v1/responses)
##
## This provider uses the /v1/responses endpoint which supports stateful conversations.
## NOTE: Client-side tools (Function Calling) are NOT supported by this endpoint in LM Studio yet.

const RESPONSE_ID_META_KEY: String = "lm_studio_response_id"

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
	
	# [重要] 暂时禁用工具，因为 LM Studio Stateful API 目前不支持 'function' 类型
	# if not p_tool_definitions.is_empty():
	# 	body["tools"] = p_tool_definitions
	
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
	
	# 第一次请求如果包含 System Prompt，目前没有标准字段发送，
	# 除非拼接到 input 里，这里暂时忽略 System Prompt 以保持简单。
	
	return body


## 处理流式响应块 (适配 LM Studio Native SSE 格式)
## 处理流式响应块 (适配 LM Studio /v1/responses 实际 SSE 格式)
func process_stream_chunk(p_target_msg: ChatMessage, p_raw_chunk: Dictionary) -> Dictionary:
	var ui_update: Dictionary = { "content_delta": "" }
	var event_type: String = p_raw_chunk.get("_event_type", "")
	
	# [调试] 打印每一个收到的块，用于确认格式
	# print("[DEBUG] Chunk: ", JSON.stringify(p_raw_chunk))
	
	# 1. 处理文本增量 (response.output_text.delta)
	if event_type == "response.output_text.delta":
		var delta: String = p_raw_chunk.get("delta", "")
		if not delta.is_empty():
			p_target_msg.content += delta
			ui_update["content_delta"] = delta
		return ui_update
	
	# 2. 处理结束事件，捕获 response_id (response.completed)
	if event_type == "response.completed":
		if p_raw_chunk.has("response"):
			var resp_obj: Dictionary = p_raw_chunk["response"]
			
			# 捕获 ID
			if resp_obj.has("id"):
				var rid: String = resp_obj["id"]
				p_target_msg.set_meta(RESPONSE_ID_META_KEY, rid)
				# print("[LMStudio] Context Saved: ", rid)
			
			# 捕获 Usage
			if resp_obj.has("usage"):
				var usage_obj: Dictionary = resp_obj["usage"]
				ui_update["usage"] = {
					"prompt_tokens": usage_obj.get("input_tokens", 0),
					"completion_tokens": usage_obj.get("output_tokens", 0),
					"total_tokens": usage_obj.get("total_tokens", 0)
				}
		return ui_update
	
	# 3. 忽略其他中间状态事件
	# response.created, response.in_progress, response.output_item.added, ...
	return ui_update
