@tool
class_name ChatController
extends RefCounted

## 聊天域控制器
##
## 负责会话管理、工作区持久化与轮数更新。
## 从 ChatHub 中抽取，使 ChatHub 只负责组合与聊天循环。


# --- Private Vars ---

var _session_manager: SessionManager
var _chat_ui: ChatUI
var _current_chat_window: CurrentChatWindow


# --- Public Functions ---

## 注入依赖
## [param p_session_manager]: 会话管理器
## [param p_chat_ui]: 主 UI 控制器
## [param p_current_chat_window]: 当前聊天窗口（视图层）
func setup(p_session_manager: SessionManager, p_chat_ui: ChatUI, p_current_chat_window: CurrentChatWindow) -> void:
	_session_manager = p_session_manager
	_chat_ui = p_chat_ui
	_current_chat_window = p_current_chat_window


## 是否有活动会话
func has_active_session() -> bool:
	return _session_manager.has_active_session()


## 创建新会话
func create_new_chat() -> void:
	var history := _session_manager.create_new_session()
	
	if history:
		_load_history_to_ui(history, _session_manager.current_session_path.get_file())
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "New Chat Created: " + _session_manager.current_session_path.get_file())
	else:
		_chat_ui.show_confirmation("Error: Failed to create chat session.")


## 加载会话
## [param p_session_name]: 会话文件名
func load_chat(p_session_name: String) -> void:
	var history := _session_manager.load_session(p_session_name)
	
	if history:
		_load_history_to_ui(history, p_session_name)
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: " + p_session_name)
	else:
		_chat_ui.show_confirmation("Error: Failed to load session: " + p_session_name)


## 删除会话
## [param p_session_name]: 会话文件名
func delete_chat(p_session_name: String) -> void:
	var is_current := (_session_manager.current_session_path.get_file() == p_session_name)
	
	if not _session_manager.delete_session(p_session_name):
		_chat_ui.show_confirmation("Error: Failed to delete session: " + p_session_name)
		return
	
	if is_current:
		var loaded_history := _session_manager.load_latest_session()
		if loaded_history:
			var loaded_name := _session_manager.current_session_path.get_file()
			_load_history_to_ui(loaded_history, loaded_name)
			_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted %s, loaded: %s" % [p_session_name, loaded_name])
		else:
			_current_chat_window.clear_session()
			_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted %s. No chats remaining." % p_session_name)
			update_turn_info()
	else:
		_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Deleted archive: " + p_session_name)
	
	_chat_ui.update_session_selector()


## 导出为 Markdown
## [param p_path]: 目标文件路径
func export_markdown(p_path: String) -> void:
	if _current_chat_window.chat_history:
		if SessionStorage.save_to_markdown(_current_chat_window.chat_history.messages, p_path):
			_chat_ui.show_confirmation("Exported to " + p_path)


## 从压缩后的历史创建新会话并加载到 UI
## [param p_history]: 压缩后生成的历史记录
## [return]: 是否成功
func create_session_from_history(p_history: ChatMessageHistory) -> bool:
	var saved_history := _session_manager.create_session_from_history(p_history)
	
	if saved_history:
		_load_history_to_ui(saved_history, _session_manager.current_session_path.get_file())
		return true
	return false


## 更新对话轮数显示
func update_turn_info() -> void:
	var settings: PluginSettingsConfig = ToolBox.get_plugin_settings()
	var history: ChatMessageHistory = _current_chat_window.chat_history
	
	if history and settings:
		_chat_ui.update_turn_display(history.get_turn_count(), settings.max_chat_turns)
	elif settings:
		_chat_ui.update_turn_display(0, settings.max_chat_turns)


## 处理工作区变更并持久化
## [param p_new_path]: 新的工作区路径
func handle_workspace_change(p_new_path: String) -> void:
	if not DirAccess.dir_exists_absolute(p_new_path):
		AIChatLogger.error("Invalid workspace path: " + p_new_path)
		return
	else:
		AIChatLogger.info("Workspace change to: " + p_new_path)
	
	var plugin_settings_res := ToolBox.get_plugin_settings()
	plugin_settings_res.workspace_path = p_new_path
	
	if ResourceSaver.save(plugin_settings_res, PluginPaths.SETTINGS_PATH) == OK:
		AIChatLogger.info("Plugin Settings Saved.")
	
	ToolBox.update_editor_filesystem(PluginPaths.SETTINGS_PATH)


## 首次初始化时加载最新会话（无活动会话时）
func load_latest_on_init() -> void:
	if not _session_manager.has_active_session():
		var history := _session_manager.load_latest_session()
		if history:
			_load_history_to_ui(history, _session_manager.current_session_path.get_file())
			_chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: " + _session_manager.current_session_path.get_file())
		else:
			create_new_chat()


# --- Private Functions ---

# 将历史加载到 UI 并绑定轮数更新信号
func _load_history_to_ui(history: ChatMessageHistory, filename: String) -> void:
	_chat_ui.select_session_by_name(filename)
	_chat_ui.reset_token_usage_display()
	_current_chat_window.load_session_history_resource(history)
	
	if history.changed.is_connected(update_turn_info):
		history.changed.disconnect(update_turn_info)
	history.changed.connect(update_turn_info)
	
	update_turn_info()
