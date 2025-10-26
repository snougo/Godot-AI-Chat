@tool
extends Node
class_name ChatBackend


# 当助手消息的所有处理（包括可能的工具流）都完成后发出。
signal assistant_message_processing_completed(assistant_response: Dictionary)
# 当工具流产生需要UI显示的中间消息时发出
signal tool_message_received(tool_message: Dictionary)
# 当工具工作流开始时发出，通知UI更新状态
signal tool_workflow_started
# 当工作流中途失败时发出
signal tool_workflow_failed(error_message: String)

var tool_executor = ToolExecutor.new()
var current_tool_workflow: ToolWorkflowManager = null
var network_manager: NetworkManager
var current_chat_window: CurrentChatWindow

var is_in_tool_workflow: bool = false


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 对模型的回复进行解析判断是否需要开启工具工作流
func process_new_assistant_response(_response_data: Dictionary) -> void:
	# 使用工具类判断是否需要启动工具工作流
	if ToolCallUtils.has_tool_call(_response_data):
		print("[ChatBackend] Tool call detected. Starting workflow...")
		_start_tool_workflow(_response_data)
	else:
		print("[ChatBackend] Plain text response. Finalizing...")
		emit_signal("assistant_message_processing_completed", _response_data)


#==============================================================================
# ## 内部函数 ##
#==============================================================================

# 启动和管理工具工作流
func _start_tool_workflow(_response_data: Dictionary) -> void:
	is_in_tool_workflow = true
	# 在启动工作流的第一时间就发出信号
	emit_signal("tool_workflow_started")
	# 获取完整的聊天历史以提供给工作流
	var full_chat_history: Array = current_chat_window.get_current_chat_messages()
	ToolBox.print_structured_context("To Tool Workflow", full_chat_history)
	# 创建并启动工作流管理器
	current_tool_workflow = ToolWorkflowManager.new(network_manager, tool_executor, full_chat_history)
	# 连接工作流的信号
	current_tool_workflow.tool_workflow_completed.connect(self._on_workflow_completed)
	current_tool_workflow.tool_workflow_failed.connect(self._on_workflow_failed)
	# 将工作流的 tool_message_generated 信号直接转发出去
	current_tool_workflow.tool_message_generated.connect(func(tool_msg): emit_signal("tool_message_received", tool_msg))
	#current_tool_workflow.tool_workflow_start(_response_data)
	
	current_tool_workflow.tool_call_resulet_received.connect(self._on_tool_call_resulet_received)
	current_tool_workflow.tool_workflow_start(_response_data)



#==============================================================================
# ## 信号回调函数 ##
#==============================================================================

func _on_tool_call_resulet_received(_context_type: String, _path: String, _content: String) -> void:
	# 过滤逻辑: 只将 folder_structure 类型的上下文存入长期记忆
	if _context_type == "folder_structure":
		LongTermMemoryManager.add_folder_context(_path, _content)


# 工作流成功结束时的回调
func _on_workflow_completed(_final_messages: Dictionary) -> void:
	print("[ChatBackend] Workflow completed successfully.")
	emit_signal("assistant_message_processing_completed", _final_messages)
	current_tool_workflow = null # 清理
	is_in_tool_workflow = false


# 工作流失败时的回调
func _on_workflow_failed(_error_message: String) -> void:
	push_error("[ChatBackend] Workflow failed: %s" % _error_message)
	emit_signal("tool_workflow_failed", _error_message)
	current_tool_workflow = null # 清理
	is_in_tool_workflow = false
