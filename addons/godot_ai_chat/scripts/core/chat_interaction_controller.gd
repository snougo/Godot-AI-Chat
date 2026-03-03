@tool
class_name ChatInteractionController
extends RefCounted

## 交互控制器
## 负责处理消息发送、流式接收、工具调用循环等核心交互逻辑。

var _chat_ui: ChatUI
var _network_manager: NetworkManager
var _agent_workflow: AgentWorkflow
var _current_chat_window: CurrentChatWindow
var _session_manager: SessionManager


# --- Built-in Functions ---

func _init(p_ui: ChatUI, p_net: NetworkManager, p_workflow:AgentWorkflow, p_window: CurrentChatWindow, p_session: SessionManager) -> void:
	_chat_ui = p_ui
	_network_manager = p_net
	_agent_workflow = p_workflow
	_current_chat_window = p_window
	_session_manager = p_session
	
	_connect_signals()


# --- Public Functions ---

## 处理用户发送消息
func handle_user_message(p_text: String) -> void:
	if not _session_manager.has_active_session() or _current_chat_window.chat_history == null:
		_chat_ui.show_confirmation("No chat active.\nPlease click 'New Button' or 'Load Button' to start.")
		return
	
	_chat_ui.clear_user_input()
	
	# 处理附件
	var processed: Dictionary = AttachmentProcessor.process_input(p_text)
	
	# 统一在一个消息中发送文本和所有图片
	# processed.images 是 [{"data":..., "mime":...}] 数组
	_current_chat_window.append_user_message(
		processed.final_text, 
		processed.images 
	)
	
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	var history: ChatMessageHistory = _current_chat_window.chat_history
	
	# 构建上下文
	var context_history: Array[ChatMessage] = ContextBuilder.build_context(history, settings)
	
	# 发起请求
	_network_manager.start_chat_stream(context_history)


## 请求停止生成
func handle_stop_requested() -> void:
	# 1. 尝试取消网络 (如果活跃，会触发 _on_stream_canceled)
	_network_manager.cancel_stream()
	# 2. 尝试取消工作流 (确保非网络活跃状态下的工具流也被取消)
	_agent_workflow.cancel_workflow()
	# 3. 兜底处理：如果状态还是忙碌（说明没有触发信号回调），则手动清理
	# 这种情况通常发生在 TOOLCALLING 状态，或者网络请求已经结束但 UI 还没更新时
	if _chat_ui.current_state != ChatUI.UIState.IDLE:
		_perform_stop_cleanup("Stopped")


# --- Private Functions ---

func _connect_signals() -> void:
	# 网络事件 -> UI 反馈
	_network_manager.new_chat_request_sending.connect(func():
		# 强制结算上一轮并重置当前计数，确保 UI 单调递增逻辑在新一轮生效
		_chat_ui.prepare_for_new_request()
		_chat_ui.update_ui_state(ChatUI.UIState.WAITING_RESPONSE)
	)
	
	# 流式响应处理
	_network_manager.new_stream_chunk_received.connect(func(chunk: Dictionary):
		if _chat_ui.current_state != ChatUI.UIState.RESPONSE_GENERATING:
			_chat_ui.update_ui_state(ChatUI.UIState.RESPONSE_GENERATING)
		_current_chat_window.handle_stream_chunk(chunk, _network_manager.current_provider)
	)
	
	_network_manager.chat_stream_request_completed.connect(_on_stream_completed)
	_network_manager.chat_request_failed.connect(_on_chat_failed)
	_network_manager.chat_stream_request_canceled.connect(_on_stream_canceled)
	
	# AgentWorkflow 事件
	_agent_workflow.tool_workflow_started.connect(_chat_ui.update_ui_state.bind(ChatUI.UIState.TOOLCALLING))
	_agent_workflow.tool_workflow_failed.connect(_on_chat_failed)
	_agent_workflow.assistant_message_ready.connect(_on_assistant_reply_completed)
	_agent_workflow.tool_message_generated.connect(_on_tool_message_generated)
	_agent_workflow.workflow_cancelled.connect(_on_stream_canceled)


func _perform_stop_cleanup(reason: String) -> void:
	# 统一执行停止后的清理工作
	var is_busy: bool = _chat_ui.current_state in [
		ChatUI.UIState.RESPONSE_GENERATING, 
		ChatUI.UIState.WAITING_RESPONSE, 
		ChatUI.UIState.TOOLCALLING
	]
	
	if is_busy:
		_current_chat_window.rollback_incomplete_message()
	
	if _current_chat_window.chat_history:
		_current_chat_window.chat_history.emit_changed()
	
	_chat_ui.update_ui_state(ChatUI.UIState.IDLE, reason)


# --- Signal Callbacks ---

func _on_stream_completed() -> void:
	# 如果处于工作流中（比如正在执行工具），不要结束 UI 状态
	if _agent_workflow.is_in_workflow:
		return
	
	var last_msg: ChatMessage = _current_chat_window.chat_history.get_last_message()
	
	# 如果最后一条是助手消息，交给 Backend 检查是否需要触发工具
	if last_msg and last_msg.role == ChatMessage.ROLE_ASSISTANT:
		_agent_workflow.process_response(last_msg)
	else:
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE)


func _on_stream_canceled() -> void:
	# 确保非网络活跃状态下的工具流也被取消
	_agent_workflow.cancel_workflow()
	# 执行清理
	_perform_stop_cleanup("Stopped")


func _on_chat_failed(p_error_msg: String) -> void:
	_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Error")
	_current_chat_window.append_error_message(p_error_msg)


func _on_assistant_reply_completed(_p_final_msg: ChatMessage, p_additional_history: Array[ChatMessage]) -> void:
	# 已处理完工具链，提交最终历史
	# ChatWindow.commit_agent_history 目前是空的，但保留接口调用以防未来扩展
	_current_chat_window.commit_agent_history(p_additional_history)
	
	if _current_chat_window.chat_history:
		_current_chat_window.chat_history.emit_changed()
	
	_chat_ui.update_ui_state(ChatUI.UIState.IDLE)


func _on_tool_message_generated(p_msg: ChatMessage) -> void:
	var img_data: PackedByteArray = PackedByteArray()
	var img_mime: String = ""
	
	# 从 images 数组提取图片数据
	if not p_msg.images.is_empty():
		var first_img: Dictionary = p_msg.images[0]
		if first_img.has("data"):
			img_data = first_img.data
			img_mime = first_img.get("mime", "image/png")
	
	_current_chat_window.append_tool_message(
		p_msg.name, 
		p_msg.content, 
		p_msg.tool_call_id, 
		img_data, 
		img_mime
	)
