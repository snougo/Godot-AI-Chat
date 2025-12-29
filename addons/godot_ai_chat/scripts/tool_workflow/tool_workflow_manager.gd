extends RefCounted
class_name ToolWorkflowManager


signal tool_workflow_completed(assistant_response: Dictionary, full_workflow_history: Array)
# 当工作流中途失败时发出
signal tool_workflow_failed(error_message: String)
# 当有工具的中间结果产生时发出，用于UI显示
signal tool_message_generated(tool_message: Dictionary)
# 当工具调用结果成功返回时发出
signal tool_call_resulet_received(context_type: String, path: String, content: String)

var network_manager: NetworkManager
var tool_executor: ToolExecutor

var full_chat_history: Array # [只读] 完整的会话历史
var tool_workflow_messages: Array = [] # [动态] 只记录本次工作流内的消息
var temp_assistant_response = {"role": "assistant", "content": ""}


func _init(_network_manager: NetworkManager, _tool_executor: ToolExecutor, _full_chat_history: Array):
	network_manager = _network_manager
	tool_executor = _tool_executor
	full_chat_history = _full_chat_history.duplicate(true)
	
	# 在初始化时就建立所有需要的连接
	network_manager.new_stream_chunk_received.connect(self._on_next_chunk)
	network_manager.chat_stream_request_completed.connect(self._on_next_stream_ended)
	network_manager.chat_request_failed.connect(self._on_next_request_failed)


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 一个专门的清理函数，用于断开所有连接
func cleanup_connections() -> void:
	if is_instance_valid(network_manager):
		if network_manager.is_connected("new_stream_chunk_received", Callable(self, "_on_next_chunk")):
			network_manager.new_stream_chunk_received.disconnect(self._on_next_chunk)
		if network_manager.is_connected("chat_stream_request_completed", Callable(self, "_on_next_stream_ended")):
			network_manager.chat_stream_request_completed.disconnect(self._on_next_stream_ended)
		if network_manager.is_connected("chat_request_failed", Callable(self, "_on_next_request_failed")):
			network_manager.chat_request_failed.disconnect(self._on_next_request_failed)


func tool_workflow_start(_response_data: Dictionary) -> void:
	_process_ai_response(_response_data)


#==============================================================================
# ## 内部函数 ##
#==============================================================================

func _process_ai_response(_response_data: Dictionary) -> void:
	# 检查是否包含工具调用
	if ToolCallUtils.has_tool_call(_response_data):
		# 助手消息只在它们被最终确定时（即从网络流接收完毕后）才被添加。
		var normalized_response: Dictionary = ToolCallUtils.tool_call_converter(_response_data)
		
		# 区分初始消息和后续消息的更新目标
		if tool_workflow_messages.is_empty():
			# 情况 A: tool_workflow_messages 为空，说明这是工作流的第一步（初始触发消息）
			# 这条消息位于 full_chat_history 的末尾，我们需要更新它
			if not full_chat_history.is_empty():
				for i in range(full_chat_history.size() - 1, -1, -1):
					if full_chat_history[i].get("role") == "assistant":
						full_chat_history[i] = normalized_response
						print("[ToolWorkflowManager] Updated initial assistant message in history with tool_calls.")
						break
		else:
			# 情况 B: tool_workflow_messages 不为空，说明这是工作流的后续步骤（多步工具调用）
			# 这条新的助手消息刚刚在 _on_next_stream_ended 中被添加到了 tool_workflow_messages 的末尾
			# 我们需要更新 tool_workflow_messages 里的这条消息，而不是去改历史记录
			var last_idx = tool_workflow_messages.size() - 1
			if last_idx >= 0 and tool_workflow_messages[last_idx].get("role") == "assistant":
				tool_workflow_messages[last_idx] = normalized_response
				print("[ToolWorkflowManager] Updated intermediate assistant message in workflow with tool_calls.")
		
		var tool_calls: Array = normalized_response.get("tool_calls", [])
		_execute_tools(tool_calls)
	
	# 如果没有工具调用，说明工作流结束
	elif _response_data.has("content"):
		# 构建并返回完整的历史片段
		var workflow_history: Array = []
		
		# 1. 获取触发工作流的那条 Assistant 消息 (现在它包含了关键的 tool_calls 信息)
		if not full_chat_history.is_empty():
			workflow_history.append(full_chat_history[-1])
		# 2. 添加工作流中间产生的所有消息 (Tool 消息, 中间 Assistant 消息)
		workflow_history.append_array(tool_workflow_messages)
		# 3. 添加最终的回复消息
		workflow_history.append(_response_data)
		# 发出信号，传递最终回复和完整历史
		emit_signal("tool_workflow_completed", _response_data, workflow_history)
	else:
		emit_signal("tool_workflow_failed", "AI response was empty.")


func _execute_tools(_tool_calls: Array) -> void:
	var tool_messages_for_api: Array = []
	var aggregated_content_for_ui: String = ""
	# 创建一个临时的、仅用于此函数作用域的字典，以跟踪本批次中已处理的路径
	var check_context_paths_in_batch: Dictionary = {}
	
	for call in _tool_calls:
		var tool_call_id = call.get("id")
		if not tool_call_id:
			push_error("Tool call from assistant was missing an 'id'. Skipping.")
			continue
		
		var function = call.get("function", {})
		# 从 'function' 字典中正确获取工具名称
		var function_name = function.get("name", "unknown_tool")
		var args_str = function.get("arguments", "{}")
		var parsed_args = JSON.parse_string(args_str)
		var result_content: String
		
		if parsed_args is Dictionary:
			# 2: 创建一个包含名称和参数的完整字典传递给执行器
			var execution_data = {
				"tool_name": function_name,
				"arguments": parsed_args
			}
			result_content = tool_executor.tool_call_execute_parsed(execution_data)
		else:
			result_content = "[SYSTEM FEEDBACK - Tool Call Failed]\nFailed to parse the 'arguments' field for tool call ID '%s'. The provided JSON string was: '%s'" % [tool_call_id, args_str]
		
		var tool_message_for_api = {
			"role": "tool",
			"name": function_name,
			"tool_call_id": tool_call_id,
			"content": result_content
		}
		tool_messages_for_api.append(tool_message_for_api)
		
		# 在生成UI消息时使用正确的 function_name 变量
		aggregated_content_for_ui += "[Tool `%s` result for call `%s`]:\n%s\n\n" % [function_name, tool_call_id, result_content]
	
	tool_workflow_messages.append_array(tool_messages_for_api)
	var tool_message_for_ui: Dictionary = {"role": "tool", "content": aggregated_content_for_ui.strip_edges()}
	emit_signal("tool_message_generated", tool_message_for_ui)
	
	_request_next_ai_step()


func _request_next_ai_step() -> void:
	temp_assistant_response.content = "" # 重置
	
	var context_for_model: Array = _build_optimized_context()
	if context_for_model.is_empty():
		# 如果上下文为空，说明可能出现问题，直接失败
		emit_signal("tool_workflow_failed", "Failed to build a valid context for the next step.")
		return
	
	ToolBox.print_structured_context("To AI Model (Tool Workflow Step)", context_for_model)
	network_manager.new_chat_stream_request(context_for_model)


func _build_optimized_context() -> Array:
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	var system_prompt: String = settings.system_prompt
	# 将启动工作流时的完整历史和当前工作流中累积的消息合并。
	# 这确保了所有中间步骤都被保留。
	var combined_history: Array = full_chat_history + tool_workflow_messages
	# 组装最终要发送给模型的历史记录
	var chat_messages_for_AI: Array = []
	
	# 放置主系统提示词
	if not system_prompt.is_empty():
		chat_messages_for_AI.append({"role": "system", "content": system_prompt})
	
	# 放置合并后的完整对话消息
	var conversation_messages: Array = combined_history.filter(func(m): return m.get("role") != "system")
	chat_messages_for_AI.append_array(conversation_messages)
	
	return chat_messages_for_AI


#==============================================================================
# ## 信号回调函数 ##
#==============================================================================

func _on_next_chunk(_chunk: String) -> void:
	temp_assistant_response.content += _chunk


func _on_next_stream_ended() -> void:
	# 这是工作流的后续步骤。一个新的助手消息已经从网络流接收完毕。
	# 这个新消息不存在于初始的 full_chat_history 中，
	# 所以我们必须在这里将它的一个拷贝添加到工作流的内部历史中。
	var new_assistant_message = temp_assistant_response.duplicate(true)
	tool_workflow_messages.append(new_assistant_message)
	# 然后再将这个新消息交给处理引擎。
	_process_ai_response(new_assistant_message)


func _on_next_request_failed(_error_message: String) -> void:
	emit_signal("tool_workflow_failed", _error_message)
