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


func _init(p_ui: ChatUI, p_net: NetworkManager, p_workflow:AgentWorkflow, p_window: CurrentChatWindow, p_session: SessionManager) -> void:
	_chat_ui = p_ui
	_network_manager = p_net
	_agent_workflow = p_workflow
	_current_chat_window = p_window
	_session_manager = p_session
	
	_connect_signals()


func _connect_signals() -> void:
	# 网络事件 -> UI 反馈
	#_network_manager.new_chat_request_sending.connect(_chat_ui.update_ui_state.bind(ChatUI.UIState.WAITING_RESPONSE))
	_network_manager.new_chat_request_sending.connect(func():
		# [修复] 强制结算上一轮并重置当前计数，确保 UI 单调递增逻辑在新一轮生效
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
	
	# AgentWorkflow 事件
	_agent_workflow.tool_workflow_started.connect(_chat_ui.update_ui_state.bind(ChatUI.UIState.TOOLCALLING))
	_agent_workflow.tool_workflow_failed.connect(_on_chat_failed)
	_agent_workflow.assistant_message_ready.connect(_on_assistant_reply_completed)
	_agent_workflow.tool_message_generated.connect(_on_tool_message_generated)


## 处理用户发送消息
func handle_user_message(p_text: String) -> void:
	if not _session_manager.has_active_session() or _current_chat_window.chat_history == null:
		_chat_ui.show_confirmation("No chat active.\nPlease click 'New Button' or 'Load Button' to start.")
		return
	
	_chat_ui.clear_user_input()
	
	# 处理附件
	var processed: Dictionary = AttachmentProcessor.process_input(p_text)
	
	# [修复] 处理多张图片
	# 逻辑：第一张图跟随文本显示，后续图片作为单独的空文本 User 消息追加
	# 这样在历史记录中会形成连续的 User 消息，大多数 LLM (OpenAI/Anthropic) 都能正确识别为连续输入
	var images: Array = processed.get("images", [])
	
	if images.is_empty():
		# 无图情况
		_current_chat_window.append_user_message(processed.final_text)
	
	else:
		# 第一条消息：文本 + 第一张图
		var first_img: Dictionary = images[0]
		_current_chat_window.append_user_message(
			processed.final_text, 
			first_img.data, 
			first_img.mime
		)
		
		# 后续消息：仅图片
		# 从索引 1 开始遍历
		for i in range(1, images.size()):
			var next_img: Dictionary = images[i]
			_current_chat_window.append_user_message(
				"", # 文本留空
				next_img.data, 
				next_img.mime
			)
	
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	var history: ChatMessageHistory = _current_chat_window.chat_history
	
	# 构建上下文
	var context_history: Array[ChatMessage] = ContextBuilder.build_context(history, settings)
	
	# 发起请求
	_network_manager.start_chat_stream(context_history)

# 处理用户发送消息
#func handle_user_message(p_text: String) -> void:
	#if not _session_manager.has_active_session() or _current_chat_window.chat_history == null:
		#_chat_ui.show_confirmation("No chat active.\nPlease click 'New Button' or 'Load Button' to start.")
		#return
	#
	#_chat_ui.clear_user_input()
	#
	# 处理附件
	#var processed: Dictionary = AttachmentProcessor.process_input(p_text)
	#
	# 追加到窗口
	#_current_chat_window.append_user_message(
		#processed.final_text, 
		#processed.image_data, 
		#processed.image_mime
	#)
	#
	#var settings: PluginSettings = ToolBox.get_plugin_settings()
	#var history: ChatMessageHistory = _current_chat_window.chat_history
	#
	# 构建上下文
	#var context_history: Array[ChatMessage] = ContextBuilder.build_context(history, settings)
	#
	# 发起请求
	#_network_manager.start_chat_stream(context_history)


## 请求停止生成
func handle_stop_requested() -> void:
	_network_manager.cancel_stream()
	_agent_workflow.cancel_workflow()
	
	var is_busy: bool = _chat_ui.current_state in [
		ChatUI.UIState.RESPONSE_GENERATING, 
		ChatUI.UIState.WAITING_RESPONSE, 
		ChatUI.UIState.TOOLCALLING
	]
	
	if is_busy:
		_current_chat_window.rollback_incomplete_message()
	
	if _current_chat_window.chat_history:
		_current_chat_window.chat_history.emit_changed()
	
	_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Stopped")


# --- Internal Signal Callbacks ---

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
	_current_chat_window.append_tool_message(
		p_msg.name, 
		p_msg.content, 
		p_msg.tool_call_id, 
		p_msg.image_data, 
		p_msg.image_mime
	)
