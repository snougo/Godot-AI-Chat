@tool
extends Node
class_name ChatBackend

signal assistant_message_ready(final_message: ChatMessage, workflow_history: Array[ChatMessage])
signal tool_message_generated(tool_message: ChatMessage)
signal tool_workflow_started
signal tool_workflow_failed(error: String)

var tool_executor = ToolExecutor.new()
var current_workflow: ToolWorkflowManager = null
var network_manager: NetworkManager
var current_chat_window: CurrentChatWindow

var is_in_workflow: bool = false


func cancel_workflow() -> void:
	if current_workflow:
		current_workflow.cleanup()
		current_workflow = null
	is_in_workflow = false


# 处理新的助手响应 (这是整个流程的入口)
# msg: 从流中构建完整的 ChatMessage 对象
func process_response(msg: ChatMessage) -> void:
	# [新增] 强制打印，看看最终收到了什么
	print("[ChatBackend] Processing response. Role: %s, Content len: %d, Tool calls: %d" % [msg.role, msg.content.length(), msg.tool_calls.size()])
	
	# 检查是否有原生的工具调用
	if not msg.tool_calls.is_empty():
		_start_tool_workflow(msg)
	else:
		var history: Array[ChatMessage] = [msg]
		emit_signal("assistant_message_ready", msg, history)


func _start_tool_workflow(trigger_msg: ChatMessage) -> void:
	is_in_workflow = true
	emit_signal("tool_workflow_started")
	
	# 获取当前完整的历史 (Array[ChatMessage])
	var full_history = current_chat_window.chat_history.messages.duplicate()
	# 必须把触发本次 workflow 的那条 assistant 消息也加进去
	# (注意：UI 上可能已经显示了这条流式消息，但历史记录里可能还没 commit)
	# 如果 CurrentChatWindow 逻辑是流式结束后立即 commit，那这里就不用加。
	# 我们假设 CurrentChatWindow 在流式结束时已经把消息加入了历史。
	
	current_workflow = ToolWorkflowManager.new(network_manager, tool_executor, full_history)
	current_workflow.completed.connect(_on_workflow_completed)
	current_workflow.failed.connect(_on_workflow_failed)
	current_workflow.tool_msg_generated.connect(func(m): emit_signal("tool_message_generated", m))
	
	# 启动工作流，直接传入包含 tool_calls 的消息
	current_workflow.start(trigger_msg)


func _on_workflow_completed(final_msg: ChatMessage, additional_history: Array[ChatMessage]) -> void:
	is_in_workflow = false
	current_workflow = null
	emit_signal("assistant_message_ready", final_msg, additional_history)


func _on_workflow_failed(err: String) -> void:
	is_in_workflow = false
	current_workflow = null
	emit_signal("tool_workflow_failed", err)
