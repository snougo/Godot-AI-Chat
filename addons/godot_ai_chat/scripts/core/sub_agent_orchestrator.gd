@tool
class_name SubAgentOrchestrator
extends Node

const REPORT_TASK_TOOL_SCRIPT = preload("res://addons/godot_ai_chat/scripts/tools/sub_agent_tool/report_task_result_tool.gd")

var skill_name: String = ""
var task_description: String = ""

var _config: SubAgentConfig
var _tools: Dictionary = {}
var _history: ChatMessageHistory


func _exit_tree():
	_clean_reference()
	AIChatLogger.info("[SubAgent] Removed from scene tree and ready to free.")


func run_task() -> String:
	_config = SubAgentConfig.get_config()
	_history = ChatMessageHistory.new()
	
	AIChatLogger.info("[Sub Agent] Starting task with skill: '%s'" % skill_name)
	
	# 1. 加载工具
	_load_isolated_tools()
	
	# 2. 组装提示词
	var skill_instruction = ""
	var skill_res: Resource = ToolRegistry.available_skills.get(skill_name)
	if skill_res and "instruction_file" in skill_res:
		var path = skill_res.instruction_file
		if FileAccess.file_exists(path):
			skill_instruction = FileAccess.get_file_as_string(path)
	
	var final_sys_prompt = _config.base_system_prompt
	if not skill_instruction.is_empty():
		final_sys_prompt += "\n\n=== SKILL INSTRUCTION ===\n" + skill_instruction
	
	_history.add_message(ChatMessage.new(ChatMessage.ROLE_SYSTEM, final_sys_prompt))
	
	var final_user_prompt = "Please execute the following task using your tools:\n\n=== TASK DESCRIPTION ===\n" + task_description
	_history.add_message(ChatMessage.new(ChatMessage.ROLE_USER, final_user_prompt))
	
	# 3. 准备 Provider
	if _config.model_name.is_empty():
		var err = "Sub Agent 启动失败：模型名称 (model_name) 为空！"
		AIChatLogger.error(err)
		_remove_sub_agent_node_from_root()
		return err
	
	var provider = ProviderFactory.create_provider(_config.api_provider)
	if not provider:
		_remove_sub_agent_node_from_root()
		return "Failed to initialize Sub Agent Provider."
	
	var is_gemini = provider is GeminiProvider
	
	# 4. 主循环（使用 HTTPClient 主线程轮询）
	var turns_taken = 0
	var final_report = ""
	var has_reported = false
	
	while turns_taken < _config.max_chat_turns:
		turns_taken += 1
		AIChatLogger.info("[Sub Agent] --- Turn %d ---" % turns_taken)
		
		# 构建流式请求
		var tool_defs = _get_tool_definitions(is_gemini)
		var body = provider.build_request_body(_config.model_name, _history.messages, _config.temperature, true, tool_defs)
		var url = provider.get_request_url(_config.api_base_url, _config.model_name, _config.api_key, true)
		var headers = provider.get_request_headers(_config.api_key, true)
		
		# 使用 HTTPClient 直接轮询（主线程，避免 StreamRequest 线程问题）
		var response = await _do_stream_request(url, headers, JSON.stringify(body), _config.network_timeout)
		
		if response.has("error"):
			AIChatLogger.error("[Sub Agent] " + response.error)
			_remove_sub_agent_node_from_root()
			return response.error
		
		var content = response.get("content", "")
		var reasoning = response.get("reasoning_content", "")
		var raw_tool_calls = response.get("tool_calls", [])
		
		if not reasoning.is_empty():
			AIChatLogger.info("[Sub Agent Thinking]:\n" + reasoning)
		if not content.is_empty():
			AIChatLogger.info("[Sub Agent Output]:\n" + content)
		
		if content.is_empty() and not raw_tool_calls.is_empty():
			content = " "
		
		var assistant_msg = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, content)
		assistant_msg.reasoning_content = reasoning
		assistant_msg.tool_calls = raw_tool_calls
		
		ToolBox.salvage_and_clean_tool_calls(assistant_msg)
		_history.add_message(assistant_msg)
		
		var clean_tool_calls = assistant_msg.tool_calls
		
		if clean_tool_calls.is_empty():
			_remove_sub_agent_node_from_root()
			AIChatLogger.warn("[Sub Agent] Stopped without calling tools.")
			return "Task aborted: Sub Agent stopped without reporting a result."
		
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
			
			var tool_inst = _tools.get(t_name)
			var t_result = ""
			if tool_inst:
				var res = await tool_inst.execute(t_args)
				
				# 多模态支持：检测工具返回的图片附件
				var has_image_attachment: bool = res.has("attachments") \
					and res.attachments is Dictionary \
					and res.attachments.has("image_data") \
					and res.attachments.image_data is PackedByteArray \
					and not res.attachments.image_data.is_empty()
				
				if has_image_attachment:
					pending_images.append({
						"data": res.attachments.image_data,
						"mime": res.attachments.get("mime", "image/png"),
						"tool_name": t_name
					})
				
				t_result = JSON.stringify(res.get("data", res), "\t")
			else:
				t_result = "[ERROR] Tool not found: " + t_name
			
			AIChatLogger.debug("[Sub Agent] Tool Result: " + t_result)
			_history.add_tool_message(t_result, call_id, t_name)
		
		# 所有工具结果之后，将图片数据注入为 User 消息
		if not pending_images.is_empty():
			var img_msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_USER, \
				"The following images were retrieved from tool execution. Please analyze their content.")
			for img in pending_images:
				img_msg.add_image(img.data, img.mime)
			_history.add_message(img_msg)
		
		if has_reported:
			_remove_sub_agent_node_from_root()
			AIChatLogger.info("[Sub Agent] Task Finished.")
			return final_report
	
	_remove_sub_agent_node_from_root()
	AIChatLogger.warn("[Sub Agent] Exceeded max turns.")
	return "Task failed: Sub Agent exceeded max turns."


# 使用 HTTPClient 在主线程轮询流式响应
func _do_stream_request(p_url: String, p_headers: PackedStringArray, p_body: String, p_timeout_s: int) -> Dictionary:
	var tracker: TimeoutTracker = TimeoutTracker.from_network_timeout(p_timeout_s)
	var has_received_first_chunk: bool = false
	
	var client = HTTPClient.new()
	
	# 解析 URL
	var protocol_pos = p_url.find("://")
	var protocol = p_url.substr(0, protocol_pos)
	var rest = p_url.substr(protocol_pos + 3)
	var host_end = rest.find("/")
	var host = rest.substr(0, host_end) if host_end != -1 else rest
	var path = rest.substr(host_end) if host_end != -1 else "/"
	var port = 443 if protocol == "https" else 80
	
	if ":" in host:
		var parts = host.split(":")
		host = parts[0]
		port = parts[1].to_int()
	
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
	
	# 读取流式响应并解析 SSE
	var result = {"content": "", "reasoning_content": "", "tool_calls": []}
	var byte_buffer = PackedByteArray()
	var text_buffer = ""
	var processed_pos = 0
	
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk = client.read_response_body_chunk()
		
		if chunk.size() > 0:
			byte_buffer.append_array(chunk)
			var text = byte_buffer.get_string_from_utf8()
			if not text.is_empty():
				byte_buffer.clear()
				text_buffer += text
				var new_text = text_buffer.substr(processed_pos)
				_parse_sse_lines(new_text, result)
				processed_pos = text_buffer.length()
				
				# 首 token 判定：基于实际内容，而非原始 HTTP chunk
				if not has_received_first_chunk:
					if not result.content.is_empty() or not result.reasoning_content.is_empty():
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
	return result


# 解析 SSE 数据行
func _parse_sse_lines(p_text: String, p_result: Dictionary) -> void:
	var lines = p_text.split("\n")
	for line in lines:
		line = line.strip_edges()
		if not line.begins_with("data: "):
			continue
		
		var json_str = line.substr(6).strip_edges()
		if json_str == "[DONE]":
			continue
		
		var json = JSON.parse_string(json_str)
		if json == null or not json is Dictionary:
			continue
		if not json.has("choices") or json.choices.is_empty():
			continue
		
		var delta = json.choices[0].get("delta", {})
		
		if delta.has("content") and delta.content is String:
			p_result.content += delta.content
		if delta.has("reasoning_content") and delta.reasoning_content is String:
			p_result.reasoning_content += delta.reasoning_content
		if delta.has("tool_calls") and delta.tool_calls is Array:
			for tc in delta.tool_calls:
				var index = int(tc.get("index", 0))
				while p_result.tool_calls.size() <= index:
					p_result.tool_calls.append({
						"id": "", "type": "function",
						"function": {"name": "", "arguments": ""}
					})
				var target = p_result.tool_calls[index]
				if tc.has("id") and tc.id != null:
					target.id = tc.id
				if tc.has("function"):
					var f = tc.function
					if f.has("name") and f.name != null:
						target.function.name += f.name
					if f.has("arguments") and f.arguments != null:
						target.function.arguments += f.arguments


func _load_isolated_tools() -> void:
	_tools.clear()
	if REPORT_TASK_TOOL_SCRIPT:
		var inst = REPORT_TASK_TOOL_SCRIPT.new()
		_tools[inst.tool_name] = inst
	
	var skill_res: Resource = ToolRegistry.available_skills.get(skill_name)
	if skill_res and "tools" in skill_res:
		for t_path in skill_res.tools:
			if FileAccess.file_exists(t_path):
				var script = load(t_path)
				if script and script is GDScript:
					var inst = script.new()
					if inst.has_method("execute"):
						_tools[inst.tool_name] = inst


func _get_tool_definitions(is_gemini: bool) -> Array:
	var defs = []
	for tool_inst in _tools.values():
		var schema = tool_inst.get_parameters_schema()
		if is_gemini:
			schema = ToolRegistry.convert_schema_to_gemini(schema)
			defs.append({
				"name": tool_inst.tool_name,
				"description": tool_inst.tool_description,
				"parameters": schema
			})
		else:
			defs.append({
				"type": "function",
				"function": {
					"name": tool_inst.tool_name,
					"description": tool_inst.tool_description,
					"parameters": schema
				}
			})
	return defs


func _remove_sub_agent_node_from_root() -> void:
	var root: Window = Engine.get_main_loop().root
	for child in root.get_children(false):
		if "SubAgentOrchestrator" in child.name and child is SubAgentOrchestrator:
			root.remove_child(child)
			queue_free()


func _clean_reference() -> void:
	_tools.clear()
	if is_instance_valid(_history):
		_history = null
