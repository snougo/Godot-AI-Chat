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

# 用于从外部取消当前正在进行的工作流
func cancel_current_workflow() -> void:
	if is_instance_valid(current_tool_workflow):
		current_tool_workflow.cleanup_connections()
		current_tool_workflow = null
		is_in_tool_workflow = false
		print("[ChatBackend] Current tool workflow canceled and cleaned up.")


# 对模型的回复进行解析判断是否需要开启工具工作流
func process_new_assistant_response(_response_data: Dictionary) -> void:
	# 关键逻辑：只在没有工作流正在进行时，才检查是否要启动一个新的工作流。
	if not is_in_tool_workflow:
		if ToolCallUtils.has_tool_call(_response_data):
			print("[ChatBackend] Tool call detected. Starting workflow...")
			_start_tool_workflow(_response_data)
		else:
			print("[ChatBackend] Plain text response. Finalizing...")
			emit_signal("assistant_message_processing_completed", _response_data)
	# 如果已有工作流正在进行，则忽略此调用，因为工作流会自我管理。
	# 这是一个安全保障，理论上 ChatHub 的检查会阻止代码执行到这里。
	else:
		print("[ChatBackend] WARN: process_new_assistant_response called while a workflow is active. Ignoring.")



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
	current_tool_workflow.tool_call_resulet_received.connect(self._on_tool_call_resulet_received)
	# 使用触发消息来启动工作流
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
	#current_tool_workflow = null
	# 关键修复：在释放引用之前，先调用清理函数
	if is_instance_valid(current_tool_workflow):
		current_tool_workflow.cleanup_connections()
		current_tool_workflow = null
	is_in_tool_workflow = false


# 工作流失败时的回调
func _on_workflow_failed(_error_message: String) -> void:
	push_error("[ChatBackend] Workflow failed: %s" % _error_message)
	emit_signal("tool_workflow_failed", _error_message)
	#current_tool_workflow = null
	# 关键修复：在释放引用之前，先调用清理函数
	if is_instance_valid(current_tool_workflow):
		current_tool_workflow.cleanup_connections()
		current_tool_workflow = null
	is_in_tool_workflow = false
