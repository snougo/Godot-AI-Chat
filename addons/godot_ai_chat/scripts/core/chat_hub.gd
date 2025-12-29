@tool
extends Control


@onready var chat_ui: ChatUI = $ChatUI
@onready var network_manager: NetworkManager = $NetworkManager
@onready var chat_backend: ChatBackend = $ChatBackend
@onready var current_chat_window: CurrentChatWindow = $CurrentChatWindow

@onready var chat_list_container: VBoxContainer = $ChatUI/TabContainer/Chat/VBoxContainer/ChatDisplayView/ScrollContainer/ChatListContainer
@onready var chat_scroll_container: ScrollContainer = $ChatUI/TabContainer/Chat/VBoxContainer/ChatDisplayView/ScrollContainer

var _is_canceling: bool = false


func _ready() -> void:
	# 在执行任何操作之前，先确保存档目录存在。
	ChatArchive.initialize_archive_directory()
	# 等待一帧，确保所有子节点都已经准备就绪
	await get_tree().process_frame
	
	# 之所以选择在ChatHub中注入依赖是因为ChatHub的子节点会早于ChatHub准备完毕
	# 因此不会出现某个子节点因没有准备好导致后续的步骤报错
	chat_backend.network_manager = self.network_manager
	chat_backend.current_chat_window = self.current_chat_window
	current_chat_window.chat_list_container = self.chat_list_container
	current_chat_window.chat_scroll_container = self.chat_scroll_container
	
	# --- 单步操作相关的信号连接，不涉及复杂的插件工作流程 ---
	chat_ui.new_chat_button_pressed.connect(current_chat_window.creat_new_chat_window)
	chat_ui.model_selection_changed.connect(network_manager.update_model_name)
	chat_ui.model_selection_changed.connect(current_chat_window.update_model_name)
	chat_ui.reconnect_button_pressed.connect(network_manager.get_model_list_from_api_service)
	
	chat_ui.summarize_button_pressed.connect(self._on_summarize_button_pressed)
	network_manager.summary_request_succeeded.connect(self._on_summary_request_succeeded)
	network_manager.summary_request_failed.connect(chat_ui.on_chat_request_failed)
	
	# --- 模型列表获取的信号连接 ---
	network_manager.get_model_list_request.connect(chat_ui.update_ui_state.bind(ChatUI.UIState.CONNECTING, "Loading Model List..."))
	network_manager.get_model_list_request_succeeded.connect(chat_ui.update_model_list)
	network_manager.get_model_list_request_failed.connect(chat_ui.on_get_model_list_request_failed)
	
	# --- 保存/加载/设置相关的信号连接 ---
	chat_ui.save_chat_button_pressed.connect(self._save_chat_messages_to_tres)
	chat_ui.save_as_markdown_button_pressed.connect(self._save_chat_messages_to_markdown)
	chat_ui.load_chat_button_pressed.connect(self._on_load_chat_archive)
	chat_ui.settings_save_button_pressed.connect(self._on_settings_saved_and_reconnect)
	
	# --- 工作流程的信号连接 ---
	# 点击发送按钮后先检查和API服务的连线
	chat_ui.send_button_pressed.connect(network_manager.connection_check)
	# 如果和API服务的连线检查成功，通知ChatUI清除用户输入框中的内容，并通知CurrentChatWindow将用户消息添加到聊天对话界面中
	network_manager.connection_check_request_succeeded.connect(chat_ui.clear_user_input)
	network_manager.connection_check_request_succeeded.connect(current_chat_window.append_new_user_message)
	# 如果和API服务的连线检查失败，通知ChatUI执行连线检查失败时的逻辑
	network_manager.connection_check_request_failed.connect(chat_ui.on_connection_check_request_failed)
	# 当用户信息在聊天对话界面中添加完毕后通知NetworkManager向模型API服务发起新会话请求并等待模型的流式回应
	current_chat_window.new_user_message_append_completed.connect(network_manager.new_chat_stream_request)
	# 为发起的新会话请求执行设定的逻辑
	network_manager.new_chat_request_sending.connect(self._on_chat_request_sending)
	# 当模型的流式输出完毕之后通知CurrentChatWindow完成模型回应消息的流式接收
	network_manager.chat_stream_request_completed.connect(current_chat_window.complete_assistant_stream_output)
	# 当模型的回应消息在聊天对话界面中添加完毕后执行设定的逻辑
	current_chat_window.new_assistant_message_append_completed.connect(self._on_new_assistant_message_appended)
	
	network_manager.chat_request_failed.connect(chat_ui.on_chat_request_failed)
	
	# 用户主动停止工作流程
	chat_ui.stop_button_pressed.connect(self._on_stop_button_pressed)
	network_manager.chat_stream_request_canceled.connect(self._on_chat_stream_canceled)
	
	# --- 工具工作流的信号连接 ---
	chat_backend.tool_workflow_started.connect(chat_ui.update_ui_state.bind(ChatUI.UIState.TOOLCALLING, "Tool Calling..."))
	chat_backend.tool_message_received.connect(current_chat_window.add_tool_message_block)
	chat_backend.assistant_message_processing_completed.connect(self._on_assistant_processing_completed)
	chat_backend.tool_workflow_failed.connect(self._on_tool_workflow_failed)
	
	# --- Token计算的信号连接 ---
	network_manager.chat_usage_data_received.connect(current_chat_window.add_token_usage)
	network_manager.fallback_token_usage_estimated.connect(current_chat_window.add_estimated_prompt_tokens)
	current_chat_window.token_cost_updated.connect(chat_ui.update_token_cost_display)
	
	# --- 初始化操作 ---
	network_manager.get_model_list_from_api_service()
	current_chat_window.creat_new_chat_window()


#==============================================================================
# ## 信号回调函数 ##
#==============================================================================

# 当设置面板保存设置后触发
func _on_settings_saved_and_reconnect() -> void:
	network_manager.get_model_list_from_api_service()
	# 将UI切换回聊天标签页
	var tab_container: TabContainer = chat_ui.get_node_or_null("TabContainer")
	if is_instance_valid(tab_container):
		tab_container.current_tab = 0


# 当UI请求加载聊天存档时触发
func _on_load_chat_archive(_archive_name: String) -> void:
	# 调用存档工具类从文件加载历史记录
	var archive_resource: PluginChatHistory = ChatArchive.load_chat_archive_from_file(_archive_name)
	
	if is_instance_valid(archive_resource):
		# 在开始加载前更新UI状态
		chat_ui.update_ui_state(ChatUI.UIState.LOADING, "Loading chat history...")
		# 加载成功，将历史消息传递给 CurrentChatWindow 进行显示
		await current_chat_window.load_chat_messages_from_archive(archive_resource.messages)
		# 加载完成后恢复UI状态
		chat_ui.update_ui_state(ChatUI.UIState.IDLE, " %s loaded." % _archive_name)
		chat_ui.show_confirmation("Chat archive '%s' loaded successfully." % _archive_name)
	else:
		# 加载失败，显示错误提示
		chat_ui.show_confirmation("Error: Failed to load chat archive '%s'." % _archive_name)


# 当UI请求将当前聊天保存为 .tres 文件时触发
func _save_chat_messages_to_tres(_save_path: String) -> void:
	# 在执行任何操作之前，先确保存档目录存在。
	ChatArchive.initialize_archive_directory()
	
	var messages: Array = current_chat_window.get_current_chat_messages()
	if messages.is_empty():
		chat_ui.show_confirmation("Cannot save an empty chat.")
		return
	
	# 创建一个新的历史记录资源并填充消息
	var history_resource: PluginChatHistory = PluginChatHistory.new()
	history_resource.messages = messages
	
	# 调用存档工具类将资源保存到文件
	var success: bool = ChatArchive.save_current_chat_to_file(history_resource, _save_path)
	if success:
		await get_tree().process_frame # 等待一帧确保文件系统更新
		chat_ui.show_confirmation("Chat successfully saved to:\n" + _save_path)
		# 刷新UI中的存档列表
		chat_ui._update_chat_archive_selector()


# 当UI请求将当前聊天导出为 Markdown 文件时触发
func _save_chat_messages_to_markdown(_save_path: String) -> void:
	# 在执行任何操作之前，先确保存档目录存在。
	ChatArchive.initialize_archive_directory()
	
	var messages: Array = current_chat_window.get_current_chat_messages()
	if messages.is_empty():
		chat_ui.show_confirmation("Cannot save an empty chat.")
		return
	
	# 调用存档工具类将消息数组转换为 Markdown 格式并保存
	var success: bool = ChatArchive.save_to_markdown(messages, _save_path)
	if success:
		await get_tree().process_frame
		chat_ui.show_confirmation("Chat successfully exported to Markdown:\n" + _save_path)
	
	# 独立地通知编辑器
	ToolBox.update_editor_filesystem(_save_path)


# 当总结按钮被按下时
func _on_summarize_button_pressed() -> void:
	var messages: Array = current_chat_window.get_current_chat_messages()
	# 过滤掉系统消息，只检查实际对话是否存在
	var conversation_messages: Array = messages.filter(func(m): return m.role != "system")
	
	if conversation_messages.is_empty():
		chat_ui.show_confirmation("Cannot summarize an empty chat.")
		return
	
	chat_ui.update_ui_state(ChatUI.UIState.SUMMARIZING, "Requesting summary...")
	print(conversation_messages)
	network_manager.request_summary(conversation_messages)


# 当总结请求成功返回时
func _on_summary_request_succeeded(summary_text: String) -> void:
	# 在使用之前，先清理总结内容可能包含的<think>内容
	var cleaned_summary: String = ToolBox.remove_think_tags(summary_text)
	
	# 保存清理后的总结到文件
	var saved_path: String = ChatArchive.save_summary_to_markdown(cleaned_summary)
	if not saved_path.is_empty():
		ToolBox.update_editor_filesystem(saved_path)
	
	# 构建新聊天的第一条消息
	var initial_message_content: String = "This is a summary of the previous conversation. Please remember it for our new chat:\n\n---\n\n" + cleaned_summary
	
	# 使用新函数初始化聊天窗口
	current_chat_window.initialize_chat_with_summarization_message("user", initial_message_content)
	
	# 恢复UI状态并显示成功信息
	chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Summary complete. New chat started.")
	chat_ui.show_confirmation("Conversation summarized and saved to:\n" + saved_path)


# 统一的停止按钮处理函数
func _on_stop_button_pressed() -> void:
	# 无论当前状态如何，立即升起“门卫”旗帜，阻止任何后续的工具流启动
	_is_canceling = true
	# 在清理主连接之前，先命令后端取消任何活动的工具工作流
	chat_backend.cancel_current_workflow()
	# 使用新的、健壮的清理函数
	_cleanup_stream_connections()
	# 尝试取消任何可能正在进行的网络请求
	network_manager.cancel_stream_request()
	# 立即更新UI状态，给用户即时反馈
	chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Canceled by user")
	# 终结当前的消息流（如果存在），这可能会同步发出 new_assistant_message_append_completed 信号
	current_chat_window.complete_assistant_stream_output()
	# 等待一帧，确保上面发出的信号已经被我们的“门卫”逻辑（_is_canceling标志）处理（拦截）完毕
	await get_tree().process_frame
	# 放下“门卫”旗帜，为下一次对话做准备
	_is_canceling = false


# 当一个新的聊天请求即将发送时调用
func _on_chat_request_sending() -> void:
	# 在建立新的流式连接之前，清理所有旧的流式连接。
	_cleanup_stream_connections()
	# 更新UI状态到“等待响应”
	chat_ui.update_ui_state(ChatUI.UIState.WAITING_RESPONSE, "Waiting for AI response...")
	# 在UI上创建新的空消息块
	current_chat_window.creat_new_assistant_message_block()
	# 建立一个一次性的连接，用于在收到第一个数据块时切换UI状态
	network_manager.new_stream_chunk_received.connect(self._on_first_stream_chunk_received, CONNECT_ONE_SHOT)
	# 建立用于追加文本块的连接
	network_manager.new_stream_chunk_received.connect(current_chat_window.append_chunk_to_assistant_message)


# 当收到第一个流式数据块时调用
func _on_first_stream_chunk_received(_chunk: String) -> void:
	# 切换UI状态到“正在生成”
	chat_ui.update_ui_state(ChatUI.UIState.RESPONSE_GENERATING, "AI is generating...")


# 它的主要职责是确保在流确实被取消后，任何部分完成的消息也能被正确终结。
# 核心的UI更新和状态管理已经移至 _on_stop_button_pressed
func _on_chat_stream_canceled() -> void:
	# 如果取消流程尚未启动（例如，由网络错误而非用户点击触发的取消），则启动它
	if not _is_canceling:
		_is_canceling = true
		chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Stream canceled")
		current_chat_window.complete_assistant_stream_output()
		await get_tree().process_frame
		_is_canceling = false


# 处理助手消息完成的中间函数，包含“门卫”检查逻辑
func _on_new_assistant_message_appended(message_data: Dictionary) -> void:
	# 如果当前正处于取消流程中，则直接忽略这个信号，不启动任何后端处理
	if _is_canceling:
		print("[ChatHub] Assistant message appended, but process is canceling. Ignoring.")
		return
	
	# 如果后端正处于一个工具工作流中，则不通过此路径处理新消息。
	# 工作流会通过其自身的网络信号监听来管理流程，避免双重处理和状态冲突。
	if chat_backend.is_in_tool_workflow:
		print("[ChatHub] Assistant message appended, but a tool workflow is active. Workflow will self-manage.")
		return
	
	# 在将控制权交给后端之前，清理当前流的信号连接。
	# 这可以防止在工具流启动新请求时发生“信号已连接”的错误。
	_cleanup_stream_connections()
	# 如果不是在取消，则正常将消息传递给后端进行处理
	chat_backend.process_new_assistant_response(message_data)


# 当 ChatBackend 的工作流成功完成时调用
func _on_assistant_processing_completed(_final_message: Dictionary, _workflow_history: Array) -> void:
	# 使用新的、健壮的清理函数
	_cleanup_stream_connections()
	# 命令 CurrentChatWindow 更新最终的消息显示
	current_chat_window.commit_final_assistant_message(_final_message, _workflow_history)
	# 命令 ChatUI 恢复空闲状态
	chat_ui.on_assistant_message_appending_complete()


# 当 ChatBackend 的工作流失败时调用
func _on_tool_workflow_failed(_error_message: String) -> void:
	# 使用新的、健壮的清理函数
	_cleanup_stream_connections()
	# 创建一个标准的错误消息字典用于显示
	var error_response = {
		"role": "assistant", 
		"content": "[ERROR] Tool execution failed: " + _error_message
	}
	
	# 错误情况下，历史片段只包含这个错误消息
	current_chat_window.commit_final_assistant_message(error_response, [error_response])
	# 命令 ChatUI 恢复空闲状态
	chat_ui.on_assistant_message_appending_complete()


#==============================================================================
# ## 内部函数 ##
#==============================================================================

# 集中处理所有与流式请求相关的信号连接的清理工作
func _cleanup_stream_connections() -> void:
	var callable = Callable(current_chat_window, "append_chunk_to_assistant_message")
	if network_manager.is_connected("new_stream_chunk_received", callable):
		network_manager.new_stream_chunk_received.disconnect(callable)
	
	# 防止某些情况下未收到第一个流式数据插件就进入错误状态
	# 导致_on_first_stream_chunk_received未被调用
	# 从而使得本该自动断掉的new_stream_chunk_received信号没有断掉
	var first_chunk_callable = Callable(self, "_on_first_stream_chunk_received")
	if network_manager.is_connected("new_stream_chunk_received", first_chunk_callable):
		network_manager.new_stream_chunk_received.disconnect(first_chunk_callable)
