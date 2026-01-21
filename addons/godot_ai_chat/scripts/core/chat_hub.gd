@tool
class_name ChatHub
extends Control

## 插件的主控制器（重构版），负责协调 UI、网络管理器、后端逻辑。
## 文件管理已移交 SessionManager，上下文构建已移交 ContextBuilder。

# --- @onready Vars ---

@onready var _chat_ui: ChatUI = $ChatUI
@onready var _network_manager: NetworkManager = $NetworkManager
@onready var _chat_backend: ChatBackend = $ChatBackend
@onready var _current_chat_window: CurrentChatWindow = $CurrentChatWindow

# --- Private Vars ---

## [Refactor] 会话管理器实例
var _session_manager: SessionManager

## 状态锁，防止新建按钮连击导致逻辑错乱
var is_creating_new_chat: bool = false


# --- Built-in Functions ---

func _ready() -> void:
	# 1. 环境准备
	ToolRegistry.load_default_tools()
	
	# [Refactor] 初始化 SessionManager
	# 必须在逻辑开始前完成初始化
	_session_manager = SessionManager.new(_chat_ui, _current_chat_window)
	
	# 2. 依赖注入
	# [Refactor] 通过 ChatUI 接口获取节点引用
	var _chat_list_container: VBoxContainer = _chat_ui.get_chat_list_container()
	var _chat_scroll_container: ScrollContainer = _chat_ui.get_chat_scroll_container()
	
	_chat_backend.network_manager = _network_manager
	_chat_backend.current_chat_window = _current_chat_window
	_current_chat_window.chat_list_container = _chat_list_container
	_current_chat_window.chat_scroll_container = _chat_scroll_container
	
	# 等待一帧让子节点 Ready
	await get_tree().process_frame
	
	# --- 信号连接 ---
	
	# UI 操作
	_chat_ui.send_button_pressed.connect(_on_user_send_message)
	_chat_ui.stop_button_pressed.connect(_on_stop_requested)
	_chat_ui.new_chat_button_pressed.connect(_create_new_chat_history)
	_chat_ui.reconnect_button_pressed.connect(_network_manager.get_model_list)
	_chat_ui.load_chat_button_pressed.connect(_load_chat_history)
	_chat_ui.settings_save_button_pressed.connect(_network_manager.get_model_list)
	_chat_ui.settings_save_button_pressed.connect(_update_turn_info)
	_chat_ui.save_as_markdown_button_pressed.connect(_export_markdown)
	
	# 模型与设置
	_chat_ui.model_selection_changed.connect(func(_model_name: String): _network_manager.current_model_name = _model_name)
	
	# 网络事件 -> UI 反馈
	_network_manager.get_model_list_request_started.connect(_chat_ui.update_ui_state.bind(ChatUI.UIState.CONNECTING))
	_network_manager.get_model_list_request_succeeded.connect(_chat_ui.update_model_list)
	_network_manager.get_model_list_request_failed.connect(_chat_ui.get_model_list_request_failed)
	
	# 网络事件 -> 发起对话
	_network_manager.new_chat_request_sending.connect(_chat_ui.update_ui_state.bind(ChatUI.UIState.WAITING_RESPONSE))
	#_network_manager.new_stream_chunk_received.connect(_on_chunk_received)
	
	# [Refactor] 修改：移除条件判断，强制状态同步
	_network_manager.new_stream_chunk_received.connect(func(_chunk: Dictionary):
		# 只要收到数据，就强制确保 UI 处于生成状态
		# 为了避免每帧都调用 update_ui_state 导致 UI 刷新开销，加一个简单的状态检查
		if _chat_ui.current_state != ChatUI.UIState.RESPONSE_GENERATING:
			_chat_ui.update_ui_state(ChatUI.UIState.RESPONSE_GENERATING)
		
		# 数据流转
		_current_chat_window.handle_stream_chunk(_chunk, _network_manager.current_provider)
	)
	
	_network_manager.chat_stream_request_completed.connect(_on_stream_completed)
	_network_manager.chat_request_failed.connect(_on_chat_failed)
	
	# 后端 Agent 事件
	_chat_backend.tool_workflow_started.connect(_chat_ui.update_ui_state.bind(ChatUI.UIState.TOOLCALLING))
	_chat_backend.tool_workflow_failed.connect(_on_chat_failed)
	_chat_backend.assistant_message_ready.connect(_on_assistant_reply_completed)
	_chat_backend.tool_message_generated.connect(_on_tool_message_generated)
	
	# Token 统计
	if not _network_manager.chat_usage_data_received.is_connected(_chat_ui.update_token_cost_display):
		_network_manager.chat_usage_data_received.connect(_chat_ui.update_token_cost_display)
	
	if not _current_chat_window.token_usage_updated.is_connected(_chat_ui.update_token_cost_display):
		_current_chat_window.token_usage_updated.connect(_chat_ui.update_token_cost_display)
	
	# --- 初始化 ---
	_network_manager.get_model_list()
	
	# [Refactor] 初始状态检查
	if not _session_manager.has_active_session():
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "No Chat Active: Please 'New' or 'Load' a chat")


# --- Public Functions ---

func get_chat_ui() -> ChatUI:
	return _chat_ui


# --- Private Functions ---

## 新建会话
func _create_new_chat_history() -> void:
	if is_creating_new_chat:
		return
	
	is_creating_new_chat = true
	_on_stop_requested()
	
	var _new_filename: String = _session_manager.create_new_session()
	
	if not _new_filename.is_empty():
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "New Chat Created: " + _new_filename)
		_connect_history_ui_signals() # <--- 新增调用
	else:
		_chat_ui.show_confirmation("Error: Failed to create chat session.")
	
	is_creating_new_chat = false


## 加载会话
func _load_chat_history(_filename: String) -> void:
	_on_stop_requested()
	
	var _success: bool = _session_manager.load_session(_filename)
	
	if _success:
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: %s" % _filename)
		_connect_history_ui_signals() # <--- 新增调用
	else:
		_chat_ui.show_confirmation("Error: Failed to load session: %s" % _filename)


## 更新 UI 上的轮数显示
func _update_turn_info() -> void:
	var _settings: PluginSettings = ToolBox.get_plugin_settings()
	var _history: ChatMessageHistory = _current_chat_window.chat_history
	
	if _history and _settings:
		var _count: int = _history.get_turn_count()
		_chat_ui.update_turn_display(_count, _settings.max_chat_turns)
	elif _settings:
		_chat_ui.update_turn_display(0, _settings.max_chat_turns)


# --- Signal Callbacks ---

## 用户点击发送
func _on_user_send_message(_text: String) -> void:
	# [Refactor] 状态检查
	if not _session_manager.has_active_session() or _current_chat_window.chat_history == null:
		_chat_ui.show_confirmation("No chat active.\nPlease click 'New Button' or 'Load Button' to start.")
		return
	
	_chat_ui.clear_user_input()
	#_current_chat_window.append_user_message(_text)
	
	# [New] 处理附件
	var processed: Dictionary = AttachmentProcessor.process_input(_text)
	
	# [Modify] 传入处理后的文本和图片数据
	_current_chat_window.append_user_message(
		processed.final_text, 
		processed.image_data, 
		processed.image_mime
	)
	
	var _settings: PluginSettings = ToolBox.get_plugin_settings()
	var _history: ChatMessageHistory = _current_chat_window.chat_history
	
	# [Refactor] 委托 ContextBuilder 构建上下文
	var _context_history: Array[ChatMessage] = ContextBuilder.build_context(_history, _settings)
	
	_network_manager.start_chat_stream(_context_history)


# 收到第一个 Chunk 时，更新 UI 状态
#func _on_chunk_received(_chunk: Dictionary) -> void:
	#if _chat_ui.current_state == ChatUI.UIState.WAITING_RESPONSE:
		#_chat_ui.update_ui_state(ChatUI.UIState.RESPONSE_GENERATING)
	
	#_current_chat_window.handle_stream_chunk(_chunk, _network_manager.current_provider)


## 显示工具结果
func _on_tool_message_generated(_msg: ChatMessage) -> void:
	_current_chat_window.append_tool_message(
		_msg.name, 
		_msg.content, 
		_msg.tool_call_id, 
		_msg.image_data, 
		_msg.image_mime
	)


## 处理流结束
func _on_stream_completed() -> void:
	if _chat_backend.is_in_workflow:
		return
	
	var _last_msg: ChatMessage = _current_chat_window.chat_history.get_last_message()
	
	if _last_msg and _last_msg.role == ChatMessage.ROLE_ASSISTANT:
		_chat_backend.process_response(_last_msg)
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
func _on_chat_failed(_error_msg: String) -> void:
	_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Error")
	_current_chat_window.append_error_message(_error_msg)


## Agent 最终回复完成
func _on_assistant_reply_completed(_final_msg: ChatMessage, _additional_history: Array[ChatMessage]) -> void:
	_current_chat_window.commit_agent_history(_additional_history)
	
	if _current_chat_window.chat_history:
		_current_chat_window.chat_history.emit_changed()
	
	_chat_ui.update_ui_state(ChatUI.UIState.IDLE)


## 导出 Markdown
func _export_markdown(_path: String) -> void:
	var _success: bool = ChatArchive.save_to_markdown(_current_chat_window.chat_history.messages, _path)
	if _success:
		_chat_ui.show_confirmation("Exported to %s" % _path)


func _connect_history_ui_signals() -> void:
	var _history: ChatMessageHistory = _current_chat_window.chat_history
	if _history:
		# 确保不重复连接
		if not _history.changed.is_connected(_update_turn_info):
			_history.changed.connect(_update_turn_info)
		
		# 立即执行一次刷新
		_update_turn_info()
