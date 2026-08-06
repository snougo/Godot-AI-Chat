@tool
class_name SubAgentOrchestrator
extends Node

const REPORT_TASK_TOOL_SCRIPT: Resource = preload("res://addons/godot_ai_chat/scripts/tools/sub_agent_tool/report_task_result_tool.gd")

var skill_name: String = ""
var task_description: String = ""

var _config: SubAgentConfig
var _history: ChatMessageHistory
var _sub_agent_tools: Dictionary = {}

# 主线程 SSE 解析临时状态（仅 _do_stream_request 使用；Sub-Agent 单线程顺序执行，无并发）
var _sse_text_buffer: String = ""
var _sse_processed_pos: int = 0
var _sse_current_event: String = ""


func _exit_tree():
	_clean_reference()
	AIChatLogger.info("[SubAgent] Removed from scene tree and ready to free.")


func run_task() -> String:
	# 优先使用技能级配置，若无则回退到全局配置
	var skill_res: Resource = ToolRegistry.available_skills.get(skill_name)
	if skill_res and skill_res.get("sub_agent_config") != null:
		_config = skill_res.sub_agent_config
	else:
		_config = SubAgentConfig.get_config()
	
	_history = ChatMessageHistory.new()
	
	AIChatLogger.info("[Sub Agent] Starting task with skill: '%s'" % skill_name)
	
	# 1. 加载工具
	_load_isolated_tools()
	
	# 2. 组装上下文（委托给 ContextBuilder）
	var context_messages: Array[ChatMessage] = ContextBuilder.build_sub_agent_context(
		_config.base_system_prompt,
		skill_name,
		task_description
	)
	for msg in context_messages:
		_history.add_message(msg)
	
	# 3. 准备 Provider
	if _config.model_name.is_empty():
		var err := "Error: Sub-Agent startup failed: model name is empty. Please configure it before invoking."
		AIChatLogger.error(err)
		_remove_sub_agent()
		return err
	
	var provider = ProviderFactory.create_provider(_config.api_provider)
	if not provider:
		_remove_sub_agent()
		return "Error: failed to initialize Sub Agent API Provider."
	
	var is_gemini: bool = provider is GeminiProvider
	# 工具定义格式（schema 生成）仍按 Gemini 特判；图片交付独立成能力查询
	var supports_inline: bool = provider.supports_inline_tool_images()
	
	# 4. 主循环（使用 HTTPClient 主线程轮询）
	var turns_taken = 0
	var final_report = ""
	var has_reported = false
	
	while turns_taken < _config.max_chat_turns:
		turns_taken += 1
		
		# 构建流式请求
		var tool_defs = _get_tool_definitions(is_gemini)
		var body = provider.build_request_body(_config.model_name, _history.messages, _config.temperature, true, tool_defs)
		var url = provider.get_request_url(_config.api_base_url, _config.model_name, _config.api_key, true)
		var headers = provider.get_request_headers(_config.api_key, true)
		
		# 使用 HTTPClient 直接轮询（主线程，避免 StreamRequest 线程问题）
		# 传入 provider 以便 SSE 解析时委托到其自身的 process_stream_chunk，
		# 让 ChatCompletions / Responses / Anthropic 三种 SSE 协议各自走自己的分派
		var response = await _do_stream_request(url, headers, JSON.stringify(body), provider, _config.network_timeout)
		
		if response.has("error"):
			AIChatLogger.error("[Sub Agent] " + response.error)
			_remove_sub_agent()
			return response.error
		
		var content = response.get("content", "")
		var reasoning = response.get("reasoning_content", "")
		var raw_tool_calls = response.get("tool_calls", [])
		
		AIChatLogger.info("[Sub Agent] --- Turn %d ---" % turns_taken)
		
		if not reasoning.is_empty():
			AIChatLogger.info("[Sub Agent Thinking]:\n" + reasoning)
		if not content.is_empty():
			AIChatLogger.info("[Sub Agent Output]:\n" + content)
		
		if content.is_empty() and not raw_tool_calls.is_empty():
			content = " "
		
		var assistant_msg = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, content)
		assistant_msg.reasoning_content = reasoning
		assistant_msg.tool_calls = raw_tool_calls
		# 回传 Anthropic extended-thinking 块的签名，多轮 thinking 会话必需
		assistant_msg.thinking_signature = response.get("thinking_signature", "")
		
		# 清洗工具调用：剔除伪调用（XML 包裹等），将被误判的文本抢救回 content
		ToolBox.salvage_and_clean_tool_calls(assistant_msg, _sub_agent_tools)
		_history.add_message(assistant_msg)
		
		var clean_tool_calls = assistant_msg.tool_calls
		
		if clean_tool_calls.is_empty():
			_remove_sub_agent()
			AIChatLogger.warn("[Sub Agent] Stopped without reporting.")
			return "Sub Agent stopped without reporting a result. Please check the status of the relevant files."
		
		# 收集本轮工具返回的图片附件
		var pending_images: Array[Dictionary] = []
		
		# 执行工具
		for tc in clean_tool_calls:
			var t_name = tc.function.name
			var args_str = tc.function.get("arguments", "{}")
			var call_id = tc.id
			
			var t_args = JSON.parse_string(JSONRepairHelper.repair_json(args_str))
			if t_args == null: t_args = {}
			
			AIChatLogger.info("[Sub Agent] Executing Tool: " + t_name)
			
			if t_name == "report_task_result":
				final_report = "Status: %s\nSummary: %s" % [t_args.get("status", "unknown"), t_args.get("summary", "")]
				has_reported = true
				break
			
			var tool_inst = _sub_agent_tools.get(t_name)
			
			var t_result = ""
			if tool_inst:
				var res: ToolResult = await tool_inst.execute(t_args)
				
				# 先获取结果文本
				t_result = res.get_data()
				
				AIChatLogger.debug("[Sub Agent] Tool Result: " + t_result)
				
				if res.has_image():
					if supports_inline:
						# 支持 inline 图片的 Provider：图片直接放入 tool 消息
						var tool_msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_TOOL, t_result, t_name)
						tool_msg.tool_call_id = call_id
						tool_msg.add_image(res.attachments.image_data, res.attachments.mime)
						_history.add_message(tool_msg)
					else:
						# 不支持 inline 图片的 Provider: 收集图片，稍后通过新增 User 消息承载
						pending_images.append({
							"data": res.attachments.image_data,
							"mime": res.attachments.get("mime", "image/png"),
							"tool_name": t_name
						})
						_history.add_tool_message(t_result, call_id, t_name)
				else:
					_history.add_tool_message(t_result, call_id, t_name)
			else:
				t_result = "[ERROR] Tool not found: " + t_name
				_history.add_tool_message(t_result, call_id, t_name)
		
		# 仅当 Provider 不支持 inline tool 图片 且模型支持视觉(VLM)时，才将图片以 User 消息注入
		if not supports_inline and _config.supports_vision and not pending_images.is_empty():
			var img_msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_USER, "The following images were retrieved from tool execution. Please analyze their content.")
			for img in pending_images:
				img_msg.add_image(img.data, img.mime)
			_history.add_message(img_msg)
		
		if has_reported:
			_remove_sub_agent()
			AIChatLogger.info("[Sub Agent] Task Finished.")
			return final_report
	
	_remove_sub_agent()
	AIChatLogger.warn("[Sub Agent] Exceeded max turns.")
	return "Sub Agent reached the maximum execution step limit and was forcibly terminated." \
	+ "Its task has been partially completed." \
	+ "Please re-invoke the Sub Agent to continue from where it left off."


# 使用 HTTPClient 在主线程轮询流式响应（解析委托 provider.process_stream_chunk 完成协议分派）
func _do_stream_request(p_url: String, p_headers: PackedStringArray, p_body: String, p_provider: BaseLLMProvider, p_timeout_s: int) -> Dictionary:
	var tracker: TimeoutTracker = TimeoutTracker.from_network_timeout(p_timeout_s)
	var has_received_first_chunk: bool = false
	
	var client = HTTPClient.new()
	
	# 解析 URL
	var url_parts: Dictionary = URLHelper.parse_url(p_url)
	var protocol: String = url_parts.protocol
	var host: String = url_parts.host
	var port: int = url_parts.port
	var path: String = url_parts.path
	
	# 连接服务器
	var tls_opts = TLSOptions.client() if protocol == "https" else null
	var err = client.connect_to_host(host, port, tls_opts)
	if err != OK:
		return {"error": "Connection failed: %s" % error_string(err)}
	
	while client.get_status() == HTTPClient.STATUS_CONNECTING or client.get_status() == HTTPClient.STATUS_RESOLVING:
		client.poll()
		if tracker.check().timed_out:
			client.close()
			return {"error": "Connection timeout (%ds)" % [tracker.get_current_timeout_ms() / 1000]}
		await get_tree().process_frame
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return {"error": "Connection failed. Status: %d" % client.get_status()}
	
	# 发送请求
	err = client.request(HTTPClient.METHOD_POST, path, p_headers, p_body)
	if err != OK:
		client.close()
		return {"error": "Request failed: %s" % error_string(err)}
	
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		if tracker.check().timed_out:
			client.close()
			return {"error": "Request timeout (%ds)" % [tracker.get_current_timeout_ms() / 1000]}
		await get_tree().process_frame
	
	if not client.has_response():
		client.close()
		return {"error": "No response from server."}
	
	var response_code = client.get_response_code()
	if response_code != 200:
		var error_body = PackedByteArray()
		while client.get_status() == HTTPClient.STATUS_BODY:
			client.poll()
			var chunk = client.read_response_body_chunk()
			if chunk.size() > 0:
				error_body.append_array(chunk)
			await get_tree().process_frame
		client.close()
		return {"error": "HTTP %d: %s" % [response_code, error_body.get_string_from_utf8()]}
	
	# 读取流式响应：每个 SSE 事件块转发给 provider.process_stream_chunk，
	# 让 OpenAI ChatCompletions / OpenAI Responses / Anthropic 三种 SSE 协议各自走自己的分派
	# 而非硬编码 choices[0].delta 结构（保持与主 Agent 路径同源但实例/历史均隔离）
	var target_msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, "")
	var byte_buffer = PackedByteArray()
	
	_sse_text_buffer = ""
	_sse_processed_pos = 0
	_sse_current_event = ""
	
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk = client.read_response_body_chunk()
		
		if chunk.size() > 0:
			byte_buffer.append_array(chunk)
			# 保留末尾可能不完整的 UTF-8 字符字节，避免跨 chunk 解码报错与数据损坏
			var keep: int = Utf8Helper.incomplete_tail_bytes(byte_buffer)
			var complete_size: int = byte_buffer.size() - keep
			if complete_size > 0:
				var complete: PackedByteArray = byte_buffer.slice(0, complete_size)
				var text: String = complete.get_string_from_utf8()
				byte_buffer = byte_buffer.slice(complete_size)  # 残留尾部留到下一 chunk
				if not text.is_empty():
					_sse_text_buffer += text
					_process_complete_sse_lines(target_msg, p_provider)
					
					# 首 token 判定：基于实际内容，而非原始 HTTP chunk
					if not has_received_first_chunk:
						if not target_msg.content.is_empty() or not target_msg.reasoning_content.is_empty():
							has_received_first_chunk = true
							tracker.mark_first_token_received()
					else:
						tracker.mark_data_received()
		else:
			# 流中停顿检测（仅在已收到实质内容后启用）
			if has_received_first_chunk and tracker.check().timed_out:
				client.close()
				return {"error": "Stream stalled: No data received for %ds" % [tracker.get_current_timeout_ms() / 1000]}
		
		await get_tree().process_frame
	
	client.close()
	
	# 补刷 byte_buffer 中残留的不完整字符（流已结束，无更多 chunk 可拼接）
	if byte_buffer.size() > 0:
		var tail_text: String = byte_buffer.get_string_from_utf8()
		if not tail_text.is_empty():
			_sse_text_buffer += tail_text
	
	# 流结束时刷出缓冲区中不完整的末行（防御性处理，保障数据不丢失）
	if _sse_processed_pos < _sse_text_buffer.length():
		var remaining: String = _sse_text_buffer.substr(_sse_processed_pos).strip_edges()
		if not remaining.is_empty():
			_parse_single_sse_line(remaining, target_msg, p_provider)
	
	return {
		"content": target_msg.content,
		"reasoning_content": target_msg.reasoning_content,
		"tool_calls": target_msg.tool_calls.duplicate(true),
		"thinking_signature": target_msg.thinking_signature
	}


# 处理文本缓冲区中所有以 \n 结尾的完整 SSE 行
# 按 rfind 找到最后一行换行，把这一批完整行一并分派
func _process_complete_sse_lines(p_target_msg: ChatMessage, p_provider: BaseLLMProvider) -> void:
	while true:
		var new_part: String = _sse_text_buffer.substr(_sse_processed_pos)
		var last_newline: int = new_part.rfind("\n")
		if last_newline == -1:
			break
		# 取出截至最后换行的整批完整行，推进处理位置
		var complete_text: String = new_part.substr(0, last_newline + 1)
		_sse_processed_pos += complete_text.length()
		for line in complete_text.split("\n"):
			line = line.strip_edges()
			if not line.is_empty():
				_parse_single_sse_line(line, p_target_msg, p_provider)


# 解析单行 SSE 内容：
# - event 行更新事件状态（Anthropic / OpenAI Responses 使用）
# - data 行注入 _event_type 后委托 provider.process_stream_chunk 完成协议级分派
#   OpenAI ChatCompletions 无 event 行，注入被跳过；其 provider 直接读 choices[0].delta
func _parse_single_sse_line(p_line: String, p_target_msg: ChatMessage, p_provider: BaseLLMProvider) -> void:
	# 1. 捕获 event 类型
	if p_line.begins_with("event:"):
		_sse_current_event = p_line.substr(6).strip_edges()
		return
	
	# 2. 跳过非 data 行（如 heartbeat / 注释 / 控制字段）
	if not p_line.begins_with("data:"):
		return
	
	var json_str: String = p_line.substr(5).strip_edges()
	if json_str == "[DONE]" or json_str.is_empty():
		return
	
	var json: Variant = JSON.parse_string(json_str)
	if json == null or not json is Dictionary:
		return
	
	# 注入 event 类型（OpenAI Responses 依赖此字段分派；Anthropic 仍走 JSON 内的 type 字段，两者并存兼容）
	if not _sse_current_event.is_empty():
		json["_event_type"] = _sse_current_event
	
	# 委托 provider 自身的流式解析逻辑（与主 Agent 路径同源但 provider 实例隔离）
	p_provider.process_stream_chunk(p_target_msg, json)


# 加载 Sub-Agent 自己的工具集
func _load_isolated_tools() -> void:
	_sub_agent_tools.clear()
	if REPORT_TASK_TOOL_SCRIPT:
		var inst = REPORT_TASK_TOOL_SCRIPT.new()
		_sub_agent_tools[inst.tool_name] = inst
	
	var skill_res: Resource = ToolRegistry.available_skills.get(skill_name)
	if skill_res and "tools" in skill_res:
		for t_path in skill_res.tools:
			if FileAccess.file_exists(t_path):
				var script = load(t_path)
				if script and script is GDScript:
					var inst = script.new()
					if inst.has_method("execute"):
						_sub_agent_tools[inst.tool_name] = inst


# 获取工具定义
func _get_tool_definitions(p_is_gemini: bool) -> Array[Dictionary]:
	return ToolRegistry.build_tool_definitions(_sub_agent_tools, p_is_gemini)


# 从编辑器根节点上移除 Sub-Agent 节点
func _remove_sub_agent() -> void:
	var root: Window = Engine.get_main_loop().root
	for child in root.get_children(false):
		if "SubAgentOrchestrator" in child.name and child is SubAgentOrchestrator:
			root.remove_child(child)
			queue_free()


func _clean_reference() -> void:
	_sub_agent_tools.clear()
	if is_instance_valid(_history):
		_history = null
