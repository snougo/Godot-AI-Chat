@tool
class_name ChatSessionController
extends RefCounted

## 会话控制器
## 负责管理会话的创建、加载、删除以及与 UI 的状态同步。

var _session_manager: SessionManager
var _chat_ui: ChatUI
var _current_chat_window: CurrentChatWindow

# 状态锁
var _is_creating_new_chat: bool = false
var _is_plugin_init: bool = false


func _init(p_session_manager: SessionManager, p_chat_ui: ChatUI, p_window: CurrentChatWindow) -> void:
	_session_manager = p_session_manager
	_chat_ui = p_chat_ui
	_current_chat_window = p_window


## 插件初始化时的自动加载逻辑
func auto_load_session() -> void:
	if _is_plugin_init:
		return
	
	_is_plugin_init = true
	
	# 防御性检查：确保没有活动会话时才自动加载
	if not _session_manager.has_active_session():
		var archive_list := SessionStorage.get_session_list()
		if not archive_list.is_empty():
			var latest_archive = archive_list[0]
			AIChatLogger.debug("[ChatSessionController] Auto-loading latest chat archive: " + latest_archive)
			
			if _session_manager.load_session(latest_archive):
				_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: %s" % latest_archive)
				_refresh_ui_connections()
			else:
				_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Failed to load latest archive")
		else:
			AIChatLogger.debug("[ChatSessionController] No archives found, creating new session automatically")
			if handle_new_chat():
				pass # handle_new_chat 已经处理了 UI 更新
			else:
				_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Failed to create new session")


## 处理新建会话
func handle_new_chat() -> bool:
	if _is_creating_new_chat:
		return false
	
	_is_creating_new_chat = true
	
	var new_filename: String = _session_manager.create_new_session()
	var success: bool = not new_filename.is_empty()
	
	if success:
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "New Chat Created: " + new_filename)
		_refresh_ui_connections()
	else:
		_chat_ui.show_confirmation("Error: Failed to create chat session.")
	
	_is_creating_new_chat = false
	return success


## 处理加载会话
func handle_load_chat(p_session_name: String) -> void:
	if _session_manager.load_session(p_session_name):
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: %s" % p_session_name)
		_refresh_ui_connections()
	else:
		_chat_ui.show_confirmation("Error: Failed to load session: %s" % p_session_name)


## 处理删除会话
func handle_delete_chat(p_session_name: String) -> void:
	# 检查被删除的是否是当前正在查看的会话
	var is_deleting_current: bool = (_session_manager.current_session_path.get_file() == p_session_name)
	
	if not _session_manager.delete_session(p_session_name):
		_chat_ui.show_confirmation("Error: Failed to delete session: %s" % p_session_name)
		return
	
	if is_deleting_current:
		# 删除了当前会话 -> 加载一个新的来填补空白
		var loaded_session: String = _session_manager.load_latest_session()
		if not loaded_session.is_empty():
			_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted %s, loaded: %s" % [p_session_name, loaded_session])
			_refresh_ui_connections()
		else:
			_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted %s. No chats remaining." % p_session_name)
			_update_turn_info() # 此时 history 为空或 null，更新为 0
	else:
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted archive: %s" % p_session_name)
	
	# 刷新下拉列表
	_chat_ui._update_session_selector()


## 导出 Markdown
func handle_export_markdown(p_path: String) -> void:
	if not _current_chat_window.chat_history:
		return
	
	var success: bool = SessionStorage.save_to_markdown(_current_chat_window.chat_history.messages, p_path)
	if success:
		_chat_ui.show_confirmation("Exported to %s" % p_path)


## 刷新 UI 信号连接（主要是轮数显示）
func _refresh_ui_connections() -> void:
	var history: ChatMessageHistory = _current_chat_window.chat_history
	if history:
		if not history.changed.is_connected(_update_turn_info):
			history.changed.connect(_update_turn_info)
		_update_turn_info()


## 更新 UI 上的轮数显示
func _update_turn_info() -> void:
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	var history: ChatMessageHistory = _current_chat_window.chat_history
	
	if history and settings:
		var count: int = history.get_turn_count()
		_chat_ui.update_turn_display(count, settings.max_chat_turns)
	elif settings:
		_chat_ui.update_turn_display(0, settings.max_chat_turns)
