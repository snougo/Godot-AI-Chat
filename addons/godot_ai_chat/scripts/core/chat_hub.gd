@tool
class_name ChatHub
extends Control

## 插件的主控制器，负责协调 UI、网络管理器、后端逻辑以及对话历史的管理。

# --- Constants ---

## 对话历史存档目录
const ARCHIVE_DIR: String = "res://addons/godot_ai_chat/chat_archives/"

# --- @onready Vars ---

@onready var _chat_ui: ChatUI = $ChatUI
@onready var _network_manager: NetworkManager = $NetworkManager
@onready var _chat_backend: ChatBackend = $ChatBackend
@onready var _current_chat_window: CurrentChatWindow = $CurrentChatWindow

@onready var _chat_list_container: VBoxContainer = $ChatUI/TabContainer/Chat/VBoxContainer/ChatDisplayView/ScrollContainer/ChatListContainer
@onready var _chat_scroll_container: ScrollContainer = $ChatUI/TabContainer/Chat/VBoxContainer/ChatDisplayView/ScrollContainer

# --- Public Vars ---

## 当前绑定的资源文件路径 (用于自动保存)
var current_history_path: String = ""
## 状态锁，防止新建按钮连击导致逻辑错乱
var is_creating_new_chat: bool = false

# --- Built-in Functions ---

func _ready() -> void:
	# 在这里注册工具，确保环境已稳定
	ToolRegistry.load_default_tools()
	
	# 确保目录存在
	if not DirAccess.dir_exists_absolute(ARCHIVE_DIR):
		DirAccess.make_dir_recursive_absolute(ARCHIVE_DIR)
	
	# 依赖注入
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
	_network_manager.new_stream_chunk_received.connect(_on_chunk_received)
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
	
	# 插件启动时，若无当前对话路径，提示用户操作
	if current_history_path.is_empty():
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "No Chat Active: Please 'New' or 'Load' a chat")

# --- Private Functions ---

## 新建会话
func _create_new_chat_history() -> void:
	if is_creating_new_chat:
		return
	
	if current_history_path.is_empty() or is_creating_new_chat == false:
		is_creating_new_chat = true
		
		# 停止当前可能的生成
		_on_stop_requested()
		
		if not DirAccess.dir_exists_absolute(ARCHIVE_DIR):
			DirAccess.make_dir_recursive_absolute(ARCHIVE_DIR)
		
		# 文件名去重逻辑
		var _now_time: Dictionary = Time.get_datetime_dict_from_system(false)
		var _base_filename: String = "chat_%d-%02d-%02d_%02d-%02d-%02d" % [_now_time.year, _now_time.month, _now_time.day, _now_time.hour, _now_time.minute, _now_time.second]
		var _extension_type: String = ".tres"
		var _final_path: String = ARCHIVE_DIR.path_join(_base_filename + _extension_type)
		
		var _counter: int = 1
		while FileAccess.file_exists(_final_path):
			_final_path = ARCHIVE_DIR.path_join("%s_%d%s" % [_base_filename, _counter, _extension_type])
			_counter += 1
		
		current_history_path = _final_path
		var _filename: String = _final_path.get_file()
		
		# 创建新资源并保存
		var _new_history: ChatMessageHistory = ChatMessageHistory.new()
		var _err: Error = ResourceSaver.save(_new_history, current_history_path)
		if _err != OK:
			_chat_ui.show_confirmation("Error: Failed to create chat file at %s" % current_history_path)
			return
		
		await get_tree().create_timer(0.2).timeout
		ToolBox.update_editor_filesystem(current_history_path)
		
		_chat_ui.select_archive_by_name(_filename)
		_chat_ui.reset_token_cost_display()
		
		_current_chat_window.load_history_resource(_new_history)
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "New Chat Created: " + _filename)
		
		is_creating_new_chat = false
		
		if not _new_history.changed.is_connected(_auto_save_history):
			_new_history.changed.connect(_auto_save_history)
		
		if not _new_history.changed.is_connected(_update_turn_info):
			_new_history.changed.connect(_update_turn_info)
		
		_update_turn_info() # 立即刷新一次


## 自动保存回调
func _auto_save_history() -> void:
	if current_history_path.is_empty():
		return
	
	var _chat_history: ChatMessageHistory = _current_chat_window.chat_history
	if _chat_history:
		ResourceSaver.save(_chat_history, current_history_path)


## 加载会话
func _load_chat_history(_filename: String) -> void:
	var _path: String = ARCHIVE_DIR.path_join(_filename)
	
	if not FileAccess.file_exists(_path):
		_chat_ui.show_confirmation("Error: File not found: %s" % _path)
		return
	
	var _chat_history: Resource = ResourceLoader.load(_path)
	if _chat_history is ChatMessageHistory:
		_on_stop_requested()
		current_history_path = _path
		
		_chat_ui.select_archive_by_name(_filename)
		_chat_ui.reset_token_cost_display()
		_current_chat_window.load_history_resource(_chat_history)
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: %s" % _filename)
		
		if not _chat_history.changed.is_connected(_auto_save_history):
			_chat_history.changed.connect(_auto_save_history)
		
		if not _chat_history.changed.is_connected(_update_turn_info):
			_chat_history.changed.connect(_update_turn_info)
		
		_update_turn_info() # 立即刷新一次
	else:
		_chat_ui.show_confirmation("Error: Invalid resource type.")


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
	if current_history_path.is_empty() or _current_chat_window.chat_history == null:
		_chat_ui.show_confirmation("No chat active.\nPlease click 'New Button' or 'Load Button' to start.")
		return
	
	_chat_ui.clear_user_input()
	_current_chat_window.append_user_message(_text)
	
	var _settings: PluginSettings = ToolBox.get_plugin_settings()
	var _context_history: Array[ChatMessage] = _current_chat_window.chat_history.get_truncated_messages(
		_settings.max_chat_turns,
		_settings.system_prompt
	)
	
	_network_manager.start_chat_stream(_context_history)


## 收到第一个 Chunk 时，更新 UI 状态
func _on_chunk_received(_chunk: Dictionary) -> void:
	if _chat_ui.current_state == ChatUI.UIState.WAITING_RESPONSE:
		_chat_ui.update_ui_state(ChatUI.UIState.RESPONSE_GENERATING)
	
	_current_chat_window.handle_stream_chunk(_chunk, _network_manager.current_provider)


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
