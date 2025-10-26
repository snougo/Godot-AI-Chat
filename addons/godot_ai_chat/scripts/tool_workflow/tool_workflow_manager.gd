extends RefCounted
class_name ToolWorkflowManager

# 当工作流成功返回最终答案时发出
signal tool_workflow_completed(assistant_response: Dictionary)
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


#==============================================================================
# ## 公共函数 ##
#==============================================================================

func tool_workflow_start(_response_data: Dictionary) -> void:
	var normalized_response: Dictionary = ToolCallUtils.tool_call_converter(_response_data)
	# 工作流的第一条消息就是AI的工具调用请求
	tool_workflow_messages.append(normalized_response)
	_process_ai_response(normalized_response)


#==============================================================================
# ## 内部函数 ##
#==============================================================================

func _process_ai_response(_response_data: Dictionary) -> void:
	if ToolCallUtils.has_tool_call(_response_data):
		var tool_calls: Array = _response_data.get("tool_calls", [])
		_execute_tools(tool_calls)
	elif _response_data.has("content"):
		# 工作流结束，最终答案就是这个 response_data
		emit_signal("tool_workflow_completed", _response_data)
	else:
		emit_signal("tool_workflow_failed", "AI response was empty.")


func _execute_tools(_tool_calls: Array) -> void:
	var tool_messages_for_api: Array = []
	var aggregated_content_for_ui: String = ""
	
	for call in _tool_calls:
		var tool_call_id = call.get("id")
		if not tool_call_id:
			push_error("Tool call from assistant was missing an 'id'. Skipping.")
			continue
		
		var function = call.get("function", {})
		# --- 修复点 1: 从 'function' 字典中正确获取工具名称 ---
		var function_name = function.get("name", "unknown_tool")
		var args_str = function.get("arguments", "{}")
		var parsed_args = JSON.parse_string(args_str)
		var result_content: String
		
		if parsed_args is Dictionary:
			# --- 修复点 2: 创建一个包含名称和参数的完整字典传递给执行器 ---
			var execution_data = {
				"tool_name": function_name,
				"arguments": parsed_args
			}
			result_content = tool_executor.tool_call_execute_parsed(execution_data)
			
			# 修改点: 发出包含 context_type 的更详细信号
			if function_name == "get_context" and not result_content.begins_with("[SYSTEM FEEDBACK"):
				var path = parsed_args.get("path", "")
				var context_type = parsed_args.get("context_type", "")
				if not path.is_empty() and not context_type.is_empty():
					emit_signal("tool_call_resulet_received", context_type, path, result_content)
		else:
			result_content = "[SYSTEM FEEDBACK - Tool Call Failed]\nFailed to parse the 'arguments' field for tool call ID '%s'. The provided JSON string was: '%s'" % [tool_call_id, args_str]
		
		var tool_message_for_api = {
			"role": "tool",
			"tool_call_id": tool_call_id,
			"content": result_content
		}
		tool_messages_for_api.append(tool_message_for_api)
		
		# --- 修复点 3: 在生成UI消息时使用正确的 function_name 变量 ---
		aggregated_content_for_ui += "[Tool `%s` result for call `%s`]:\n%s\n\n" % [function_name, tool_call_id, result_content]
	
	tool_workflow_messages.append_array(tool_messages_for_api)
	var tool_message_for_ui: Dictionary = {"role": "tool", "content": aggregated_content_for_ui.strip_edges()}
	emit_signal("tool_message_generated", tool_message_for_ui)
	
	_request_next_ai_step()


func _request_next_ai_step() -> void:
	temp_assistant_response.content = "" # 重置
	network_manager.new_stream_chunk_received.connect(self._on_next_chunk)
	network_manager.chat_stream_request_completed.connect(self._on_next_stream_ended, CONNECT_ONE_SHOT)
	network_manager.chat_request_failed.connect(self._on_next_request_failed, CONNECT_ONE_SHOT)
	
	var context_for_model: Array = _build_optimized_context()
	if context_for_model.is_empty():
		return
	
	ToolBox.print_structured_context("To AI Model (Tool Workflow Step)", context_for_model)
	network_manager.new_chat_stream_request(context_for_model)


func _build_optimized_context() -> Array:
	var optimized_history: Array = []
	
	# 1. 准备合并后的最终系统提示词
	var final_system_prompt: String = ""
	if not full_chat_history.is_empty() and full_chat_history[0].role == "system":
		final_system_prompt = full_chat_history[0].content
	
	var remembered_folder_context: Dictionary = LongTermMemoryManager.get_all_folder_context()
	if not remembered_folder_context.is_empty():
		var memory_string: String = "\n\n## Long-Term Memory: Folder Context\nThis is folder structure information you have already retrieved. Do not request it again.\n"
		for path in remembered_folder_context:
			var folder_tree = ToolBox.extract_folder_tree_from_context(remembered_folder_context[path])
			memory_string += "\n--- Context for folder: %s ---\n```\n%s\n```" % [path, folder_tree]
		
		final_system_prompt += memory_string
	
	# 2. 将合并后的系统提示词作为第一条消息
	if not final_system_prompt.is_empty():
		optimized_history.append({"role": "system", "content": final_system_prompt})
	
	# 3. 添加触发本次工作流的用户消息 (任务起点)
	var initiating_user_message = full_chat_history.filter(func(m): return m.role == "user").back()
	if initiating_user_message:
		optimized_history.append(initiating_user_message)
	else:
		push_error("ToolWorkflowManager: Could not find the initiating user message.")
		emit_signal("tool_workflow_failed", "Could not find the initiating user message.")
		return []
	
	# 4. 添加当前工作流的完整消息序列
	optimized_history.append_array(tool_workflow_messages)
	
	return optimized_history


#==============================================================================
# ## 信号回调函数 ##
#==============================================================================

func _on_next_chunk(_chunk: String) -> void:
	temp_assistant_response.content += _chunk


func _on_next_stream_ended() -> void:
	network_manager.new_stream_chunk_received.disconnect(_on_next_chunk)
	# 将新收到的AI响应添加到工作流历史
	tool_workflow_messages.append(temp_assistant_response)
	_process_ai_response(temp_assistant_response.duplicate())


func _on_next_request_failed(_error_message: String) -> void:
	network_manager.new_stream_chunk_received.disconnect(_on_next_chunk)
	emit_signal("tool_workflow_failed", _error_message)
