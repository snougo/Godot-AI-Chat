@tool
class_name ChatHub
extends Control

## 聊天中心控制器
##
## 插件的主入口，协调 UI、网络、会话和 Agent 各模块的交互。

# --- @onready Vars ---

@onready var _chat_ui: ChatUI = $ChatUI
@onready var _network_manager: NetworkManager = $NetworkManager
@onready var _current_chat_window: CurrentChatWindow = $CurrentChatWindow
@onready var _agent_orchestrator: AgentOrchestrator = $AgentOrchestrator

# --- Private Vars ---

var _session_manager: SessionManager
var _is_performing_cleanup: bool = false
var _is_plugin_init: bool = false


# --- Built-in Functions ---

func _ready() -> void:
	ToolRegistry.load_default_tools()
	_session_manager = SessionManager.new()
	
	_agent_orchestrator.network_manager = _network_manager
	_agent_orchestrator.current_chat_window = _current_chat_window
	# 将 ChatUI 注入给 Agent，方便它在执行工具时切换 UI 状态
	_agent_orchestrator.chat_ui = _chat_ui
	
	_current_chat_window.chat_list_container = _chat_ui.get_chat_list_container()
	_current_chat_window.chat_scroll_container = _chat_ui.get_chat_scroll_container()
	
	await get_tree().process_frame
	_bind_ui_signals()


# --- Public Functions ---

func get_chat_ui() -> ChatUI:
	return _chat_ui


# --- Private Functions ---

func _bind_ui_signals() -> void:
	_chat_ui.mouse_entered.connect(_on_chat_ui_mouse_entered)
	
	_chat_ui.new_chat_button_pressed.connect(_on_new_chat_requested)
	_chat_ui.load_chat_button_pressed.connect(_on_load_chat_requested)
	_chat_ui.delete_chat_button_pressed.connect(_on_delete_chat_requested)
	_chat_ui.save_as_markdown_button_pressed.connect(_on_export_markdown_requested)
	
	_chat_ui.send_button_pressed.connect(_on_user_send_message)
	_chat_ui.stop_button_pressed.connect(_on_stop_requested)
	
	_chat_ui.reconnect_button_pressed.connect(_network_manager.get_model_list)
	
	_chat_ui.settings_save_button_pressed.connect(func():
		_network_manager.get_model_list()
		_update_turn_info()
	)
	
	_chat_ui.model_selection_changed.connect(func(model_name: String): _network_manager.current_model_name = model_name)
	
	_network_manager.get_model_list_request_started.connect(_chat_ui.update_ui_state.bind(ChatUI.UIState.CONNECTING))
	_network_manager.get_model_list_request_succeeded.connect(_chat_ui.update_model_list)
	_network_manager.get_model_list_request_failed.connect(_chat_ui.get_model_list_request_failed)
	
	_network_manager.new_chat_request_sending.connect(_chat_ui.prepare_for_new_request)
	_network_manager.chat_usage_data_received.connect(_chat_ui.update_token_usage_display)
	_current_chat_window.token_usage_updated.connect(_chat_ui.update_token_usage_display)


func _run_chat_loop() -> void:
	_chat_ui.update_ui_state(ChatUI.UIState.WAITING_RESPONSE)
	
	if not _network_manager.new_stream_chunk_received.is_connected(_on_stream_chunk):
		_network_manager.new_stream_chunk_received.connect(_on_stream_chunk)
	
	var settings: PluginSettingsConfig = ToolBox.get_plugin_settings()
	
	# === 控制流收口：协程挂起，直至整个工具链生成结束 ===
	await _agent_orchestrator.run_chat_cycle(_current_chat_window.chat_history, settings)
	
	if _network_manager.new_stream_chunk_received.is_connected(_on_stream_chunk):
		_network_manager.new_stream_chunk_received.disconnect(_on_stream_chunk)
	
	if _agent_orchestrator._is_cancelled:
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Stopped")
		_current_chat_window.rollback_incomplete_message()
	else:
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE)
	
	if _current_chat_window.chat_history:
		_current_chat_window.chat_history.emit_changed()


func _load_history_to_ui(history: ChatMessageHistory, filename: String) -> void:
	_chat_ui.select_session_by_name(filename)
	_chat_ui.reset_token_usage_display()
	_current_chat_window.load_session_history_resource(history)
	
	# 监听历史记录变化信号，实时更新对话轮数
	if history.changed.is_connected(_update_turn_info):
		history.changed.disconnect(_update_turn_info)
	history.changed.connect(_update_turn_info)
	
	_update_turn_info()


func _update_turn_info() -> void:
	var settings: PluginSettingsConfig = ToolBox.get_plugin_settings()
	var history: ChatMessageHistory = _current_chat_window.chat_history
	
	if history and settings:
		_chat_ui.update_turn_display(history.get_turn_count(), settings.max_chat_turns)
	elif settings:
		_chat_ui.update_turn_display(0, settings.max_chat_turns)


# --- Signal Callbacks ---

func _on_user_send_message(text: String) -> void:
	if not _session_manager.has_active_session() or not _current_chat_window.chat_history:
		_chat_ui.show_confirmation("No chat active. Please click 'New Chat' or 'Load Chat' to start.")
		return
	
	_chat_ui.clear_user_input()
	var processed: Dictionary = AttachmentProcessor.process_input(text)
	_current_chat_window.append_user_message(processed.final_text, processed.images)
	
	_run_chat_loop()


func _on_stream_chunk(chunk: Dictionary) -> void:
	if _chat_ui.current_state != ChatUI.UIState.RESPONSE_GENERATING:
		_chat_ui.update_ui_state(ChatUI.UIState.RESPONSE_GENERATING)
	
	_current_chat_window.handle_stream_chunk(chunk, _network_manager.current_provider)


func _on_stop_requested() -> void:
	if _is_performing_cleanup: return
	_is_performing_cleanup = true
	_agent_orchestrator.cancel_workflow()
	_is_performing_cleanup = false


func _on_new_chat_requested() -> void:
	_on_stop_requested()
	var history := _session_manager.create_new_session()
	
	if history:
		_load_history_to_ui(history, _session_manager.current_session_path.get_file())
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "New Chat Created: " + _session_manager.current_session_path.get_file())
	else:
		_chat_ui.show_confirmation("Error: Failed to create chat session.")


func _on_load_chat_requested(session_name: String) -> void:
	_on_stop_requested()
	var history := _session_manager.load_session(session_name)
	
	if history:
		_load_history_to_ui(history, session_name)
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: " + session_name)
	else:
		_chat_ui.show_confirmation("Error: Failed to load session: " + session_name)


func _on_delete_chat_requested(session_name: String) -> void:
	var is_current := (_session_manager.current_session_path.get_file() == session_name)
	
	if not _session_manager.delete_session(session_name):
		_chat_ui.show_confirmation("Error: Failed to delete session: " + session_name)
		return
	
	if is_current:
		var loaded_history := _session_manager.load_latest_session()
		if loaded_history:
			var loaded_name = _session_manager.current_session_path.get_file()
			_load_history_to_ui(loaded_history, loaded_name)
			_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted %s, loaded: %s" % [session_name, loaded_name])
		else:
			_current_chat_window.chat_history = null
			for child in _current_chat_window.chat_list_container.get_children():
				child.queue_free()
			_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted %s. No chats remaining." % session_name)
			_update_turn_info()
	else:
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted archive: " + session_name)
	
	_chat_ui._update_session_selector()


func _on_export_markdown_requested(path: String) -> void:
	if _current_chat_window.chat_history:
		if SessionStorage.save_to_markdown(_current_chat_window.chat_history.messages, path):
			_chat_ui.show_confirmation("Exported to " + path)


func _on_chat_ui_mouse_entered() -> void:
	if _chat_ui.mouse_entered.is_connected(_on_chat_ui_mouse_entered):
		_chat_ui.mouse_entered.disconnect(_on_chat_ui_mouse_entered)
		
		if not _is_plugin_init:
			_is_plugin_init = true
			if not _session_manager.has_active_session():
				var history := _session_manager.load_latest_session()
				if history:
					_load_history_to_ui(history, _session_manager.current_session_path.get_file())
					_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: " + _session_manager.current_session_path.get_file())
				else:
					_on_new_chat_requested()
		
		await get_tree().create_timer(0.5).timeout
		_network_manager.get_model_list()
