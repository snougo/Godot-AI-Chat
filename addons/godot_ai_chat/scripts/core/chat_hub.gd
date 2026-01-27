@tool
class_name ChatHub
extends Control

## 插件主控制器
##
## 负责协调 UI、网络管理器、后端逻辑。文件管理已移交 SessionManager，上下文构建已移交 ContextBuilder。

# --- @onready Vars ---

@onready var _chat_ui: ChatUI = $ChatUI
@onready var _network_manager: NetworkManager = $NetworkManager
@onready var _chat_backend: ChatBackend = $ChatBackend
@onready var _current_chat_window: CurrentChatWindow = $CurrentChatWindow

# --- Private Vars ---

## 会话管理器实例
var _session_manager: SessionManager

## 状态锁，防止新建按钮连击导致逻辑错乱
var _is_creating_new_chat: bool = false


# --- Built-in Functions ---

func _ready() -> void:
	# 1. 环境准备
	ToolRegistry.load_default_tools()
	
	# 初始化 SessionManager
	# 必须在逻辑开始前完成初始化
	_session_manager = SessionManager.new(_chat_ui, _current_chat_window)
	
	# 2. 依赖注入
	# 通过 ChatUI 接口获取节点引用
	var chat_list_container: VBoxContainer = _chat_ui.get_chat_list_container()
	var chat_scroll_container: ScrollContainer = _chat_ui.get_chat_scroll_container()
	
	_chat_backend.network_manager = _network_manager
	_chat_backend.current_chat_window = _current_chat_window
	_current_chat_window.chat_list_container = chat_list_container
	_current_chat_window.chat_scroll_container = chat_scroll_container
	
	# 等待一帧让子节点 Ready
	await get_tree().process_frame
	
	# --- 信号连接 ---
	_chat_ui.mouse_entered.connect(_on_chat_ui_mouse_entered)
	
	# UI 操作
	_chat_ui.delete_chat_button_pressed.connect(_on_delete_chat_history)
	_chat_ui.load_chat_button_pressed.connect(_on_load_chat_history)
	_chat_ui.new_chat_button_pressed.connect(_on_create_new_chat)
	
	_chat_ui.reconnect_button_pressed.connect(_network_manager.get_model_list)
	
	_chat_ui.save_as_markdown_button_pressed.connect(_export_markdown)
	_chat_ui.send_button_pressed.connect(_on_user_send_message)
	_chat_ui.stop_button_pressed.connect(_on_stop_requested)
	
	_chat_ui.settings_save_button_pressed.connect(_network_manager.get_model_list)
	_chat_ui.settings_save_button_pressed.connect(_update_turn_info)
	
	# 模型与设置
	_chat_ui.model_selection_changed.connect(func(model_name: String): _network_manager.current_model_name = model_name)
	
	# 网络事件 -> UI 反馈
	_network_manager.get_model_list_request_started.connect(_chat_ui.update_ui_state.bind(ChatUI.UIState.CONNECTING))
	_network_manager.get_model_list_request_succeeded.connect(_chat_ui.update_model_list)
	_network_manager.get_model_list_request_failed.connect(_chat_ui.get_model_list_request_failed)
	
	# 网络事件 -> 发起对话
	_network_manager.new_chat_request_sending.connect(_chat_ui.update_ui_state.bind(ChatUI.UIState.WAITING_RESPONSE))
	
	# 移除条件判断，强制状态同步
	_network_manager.new_stream_chunk_received.connect(func(chunk: Dictionary):
		# 只要收到数据，就强制确保 UI 处于生成状态
		# 为了避免每帧都调用 update_ui_state 导致 UI 刷新开销，加一个简单的状态检查
		if _chat_ui.current_state != ChatUI.UIState.RESPONSE_GENERATING:
			_chat_ui.update_ui_state(ChatUI.UIState.RESPONSE_GENERATING)
		
		# 数据流转
		_current_chat_window.handle_stream_chunk(chunk, _network_manager.current_provider)
	)
	
	_network_manager.chat_stream_request_completed.connect(_on_stream_completed)
	_network_manager.chat_request_failed.connect(_on_chat_failed)
	
	# 后端 Agent 事件
	_chat_backend.tool_workflow_started.connect(_chat_ui.update_ui_state.bind(ChatUI.UIState.TOOLCALLING))
	_chat_backend.tool_workflow_failed.connect(_on_chat_failed)
	_chat_backend.assistant_message_ready.connect(_on_assistant_reply_completed)
	_chat_backend.tool_message_generated.connect(_on_tool_message_generated)
	
	# Token 统计
	_network_manager.chat_usage_data_received.connect(_chat_ui.update_token_cost_display)
	_current_chat_window.token_usage_updated.connect(_chat_ui.update_token_cost_display)
	
	# --- 初始化 ---
	_network_manager.get_model_list()


# --- Public Functions ---

func get_chat_ui() -> ChatUI:
	return _chat_ui


# --- Private Functions ---

## 更新 UI 上的轮数显示
func _update_turn_info() -> void:
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	var history: ChatMessageHistory = _current_chat_window.chat_history
	
	if history and settings:
		var count: int = history.get_turn_count()
		_chat_ui.update_turn_display(count, settings.max_chat_turns)
	elif settings:
		_chat_ui.update_turn_display(0, settings.max_chat_turns)


# --- Signal Callbacks ---

## 当鼠标进入ChatUI时触发
func _on_chat_ui_mouse_entered() -> void:
	# 自动加载最近的对话存档
	# 防御性检查：确保没有活动会话时才自动加载
	if not _session_manager.has_active_session():
		var archive_list := ChatArchive.get_archive_list()
		if not archive_list.is_empty():
			# 加载最新的存档（get_archive_list() 已按时间倒序排列）
			var latest_archive = archive_list[0]
			AIChatLogger.debug("[Godot AI Chat] Auto-loading latest chat archive: " + latest_archive)
			
			var is_success: bool = _session_manager.load_session(latest_archive)
			if is_success:
				_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: %s" % latest_archive)
				_connect_history_ui_signals()
			else:
				_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Failed to load latest archive")
		else:
			# 如果没有存档，保持原有行为
			_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "No Chat Active: Please 'New' or 'Load' a chat")


## 新建会话
func _on_create_new_chat() -> void:
	if _is_creating_new_chat:
		return
	
	_is_creating_new_chat = true
	_on_stop_requested()
	
	var new_filename: String = _session_manager.create_new_session()
	
	if not new_filename.is_empty():
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "New Chat Created: " + new_filename)
		_connect_history_ui_signals() # <--- 新增调用
	else:
		_chat_ui.show_confirmation("Error: Failed to create chat session.")
	
	_is_creating_new_chat = false


## 加载会话
func _on_load_chat_history(p_filename: String) -> void:
	_on_stop_requested()
	
	var success: bool = _session_manager.load_session(p_filename)
	
	if success:
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: %s" % p_filename)
		_connect_history_ui_signals() # <--- 新增调用
	else:
		_chat_ui.show_confirmation("Error: Failed to load session: %s" % p_filename)


## 删除会话并加载最新存档
func _on_delete_chat_history(p_filename: String) -> void:
	# 检查被删除的是否是当前正在查看的会话
	# 通过 SessionManager 获取当前路径的文件名进行比对
	var is_deleting_current: bool = false
	if _session_manager.current_history_path.get_file() == p_filename:
		is_deleting_current = true
	
	# 调用 SessionManager 删除文件
	var deleted: bool = _session_manager.delete_session(p_filename)
	
	if not deleted:
		_chat_ui.show_confirmation("Error: Failed to delete session: %s" % p_filename)
		return
	
	# 分情况处理 UI 更新
	if is_deleting_current:
		# 情况 A: 删除了当前会话 -> 需要加载一个新的来填补空白
		var loaded_session: String = _session_manager.load_latest_session()
		
		if not loaded_session.is_empty():
			_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted %s, loaded: %s" % [p_filename, loaded_session])
			_connect_history_ui_signals()
		else:
			# 情况 A-2: 删光了所有会话
			_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted %s. No chats remaining." % p_filename)
			_chat_ui.update_turn_display(0, ToolBox.get_plugin_settings().max_chat_turns)
	else:
		# 情况 B: 删除了后台会话 -> 仅提示，不跳转，不打断当前阅读
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted archive: %s" % p_filename)
	
	# 无论哪种情况，都要刷新下拉列表以移除已删除的项
	_chat_ui._update_chat_archive_selector()


## 用户点击发送
func _on_user_send_message(p_text: String) -> void:
	# [Refactor] 状态检查
	if not _session_manager.has_active_session() or _current_chat_window.chat_history == null:
		_chat_ui.show_confirmation("No chat active.\nPlease click 'New Button' or 'Load Button' to start.")
		return
	
	_chat_ui.clear_user_input()
	
	# 处理附件
	var processed: Dictionary = AttachmentProcessor.process_input(p_text)
	
	# 传入处理后的文本和图片数据
	_current_chat_window.append_user_message(
		processed.final_text, 
		processed.image_data, 
		processed.image_mime
	)
	
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	var history: ChatMessageHistory = _current_chat_window.chat_history
	
	# [Refactor] 委托 ContextBuilder 构建上下文
	var context_history: Array[ChatMessage] = ContextBuilder.build_context(history, settings)
	
	_network_manager.start_chat_stream(context_history)


## 显示工具结果
func _on_tool_message_generated(p_msg: ChatMessage) -> void:
	_current_chat_window.append_tool_message(
		p_msg.name, 
		p_msg.content, 
		p_msg.tool_call_id, 
		p_msg.image_data, 
		p_msg.image_mime
	)


## 处理流结束
func _on_stream_completed() -> void:
	if _chat_backend.is_in_workflow:
		return
	
	var last_msg: ChatMessage = _current_chat_window.chat_history.get_last_message()
	
	if last_msg and last_msg.role == ChatMessage.ROLE_ASSISTANT:
		_chat_backend.process_response(last_msg)
	else:
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE)


## 停止请求
func _on_stop_requested() -> void:
	_network_manager.cancel_stream()
	_chat_backend.cancel_workflow()
	
	# [Fix] 回滚逻辑保持不变
	var is_response_generating: bool = _chat_ui.current_state == ChatUI.UIState.RESPONSE_GENERATING
	var is_waiting_response: bool = _chat_ui.current_state == ChatUI.UIState.WAITING_RESPONSE
	var is_tool_calling: bool = _chat_ui.current_state == ChatUI.UIState.TOOLCALLING
	if is_response_generating or is_waiting_response or is_tool_calling:
		_current_chat_window.rollback_incomplete_message()
	
	if _current_chat_window.chat_history:
		_current_chat_window.chat_history.emit_changed()
	
	_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Stopped")


## 聊天失败 (网络错误或 Agent 错误)
func _on_chat_failed(p_error_msg: String) -> void:
	_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Error")
	_current_chat_window.append_error_message(p_error_msg)


## Agent 最终回复完成
func _on_assistant_reply_completed(_p_final_msg: ChatMessage, p_additional_history: Array[ChatMessage]) -> void:
	_current_chat_window.commit_agent_history(p_additional_history)
	
	if _current_chat_window.chat_history:
		_current_chat_window.chat_history.emit_changed()
	
	_chat_ui.update_ui_state(ChatUI.UIState.IDLE)


## 导出 Markdown
func _export_markdown(p_path: String) -> void:
	var success: bool = ChatArchive.save_to_markdown(_current_chat_window.chat_history.messages, p_path)
	if success:
		_chat_ui.show_confirmation("Exported to %s" % p_path)


func _connect_history_ui_signals() -> void:
	var history: ChatMessageHistory = _current_chat_window.chat_history
	if history:
		# 确保不重复连接
		if not history.changed.is_connected(_update_turn_info):
			history.changed.connect(_update_turn_info)
		
		# 立即执行一次刷新
		_update_turn_info()
