class_name SessionManager
extends RefCounted

## 会话管理器
##
## 负责聊天会话的创建、加载、删除和自动保

# --- Public Vars ---

var current_session_path: String = ""

# --- Private Vars ---

var _current_history: ChatMessageHistory = null


# --- Public Functions ---

## 创建新会话
## [return]: 新创建的历史记录对象，失败返回 null
func create_new_session() -> ChatMessageHistory:
	return _save_as_new_session(ChatMessageHistory.new(), "")


## 从已有历史创建新会话（用于上下文压缩后的新会话加载）
## [param p_history]: 预构建好的历史记录对象
## [return]: 保存并绑定后的历史记录对象，失败返回 null
func create_session_from_history(p_history: ChatMessageHistory) -> ChatMessageHistory:
	return _save_as_new_session(p_history, "_compressed")


## 分叉会话：将给定历史保存为新的会话文件
## [param p_history]: 要分叉保存的历史对象
## [return]: 保存并绑定后的历史记录对象，失败返回 null
func fork_session(p_history: ChatMessageHistory) -> ChatMessageHistory:
	return _save_as_new_session(p_history, "")


## 加载会话
## [param p_session_name]: 会话文件名
## [return]: 加载的历史记录对象，失败返回 null
func load_session(p_session_name: String) -> ChatMessageHistory:
	var path: String = PluginPaths.SESSION_DIR.path_join(p_session_name)
	if FileAccess.file_exists(path):
		var resource = ResourceLoader.load(path)
		if resource is ChatMessageHistory:
			_disconnect_auto_save()
			current_session_path = path
			_current_history = resource
			_bind_auto_save(resource)
			return resource
	return null


## 删除会话
## [param p_session_name]: 会话文件名
## [return]: 是否删除成功
func delete_session(p_session_name: String) -> bool:
	var archive_path: String = PluginPaths.SESSION_DIR.path_join(p_session_name)
	if not FileAccess.file_exists(archive_path):
		return false
	if DirAccess.remove_absolute(archive_path) == OK:
		if current_session_path == archive_path:
			_disconnect_auto_save()
			current_session_path = ""
			_current_history = null
		ToolBox.update_editor_filesystem(archive_path)
		return true
	return false


## 加载最新的会话
## [return]: 加载的历史记录对象，如果没有则返回 null
func load_latest_session() -> ChatMessageHistory:
	var archive_list := SessionStorage.get_session_list()
	if not archive_list.is_empty():
		return load_session(archive_list[0])
	return null


## 检查是否有活动会话
## [return]: 是否有活动会话
func has_active_session() -> bool:
	return not current_session_path.is_empty()


## 保存当前会话
## [param p_history]: 历史记录对象
func save_current_session(history: ChatMessageHistory) -> void:
	if not current_session_path.is_empty() and history:
		_validate_message_integrity(history)
		ResourceSaver.save(history, current_session_path)


# --- Private Functions ---

# 将给定历史保存为新的会话文件（生成时间戳文件名 + 躲重名）
# [param p_history]: 要保存的历史对象
# [param p_name_suffix]: 文件名后缀（如 "_compressed"，新建为空串）
# [return]: 保存成功的历史对象，失败返回 null
func _save_as_new_session(p_history: ChatMessageHistory, p_name_suffix: String) -> ChatMessageHistory:
	_ensure_archive_dir()
	_disconnect_auto_save()
	var now: Dictionary = Time.get_datetime_dict_from_system(false)
	var base := "chat_%d-%02d-%02d_%02d-%02d-%02d%s" % [now.year, now.month, now.day, now.hour, now.minute, now.second, p_name_suffix]
	var path := PluginPaths.SESSION_DIR.path_join(base + ".tres")
	var counter := 1
	while FileAccess.file_exists(path):
		path = PluginPaths.SESSION_DIR.path_join("%s_%d.tres" % [base, counter])
		counter += 1
	if ResourceSaver.save(p_history, path) == OK:
		current_session_path = path
		_current_history = p_history
		ToolBox.update_editor_filesystem(path)
		_bind_auto_save(p_history)
		return p_history
	AIChatLogger.error("[SessionManager] Failed to save session: %s" % path)
	return null


# 确保存档目录存在
func _ensure_archive_dir() -> void:
	if not DirAccess.dir_exists_absolute(PluginPaths.SESSION_DIR):
		DirAccess.make_dir_recursive_absolute(PluginPaths.SESSION_DIR)


# 断开当前历史绑定的自动保存信号（不置空 _current_history）
func _disconnect_auto_save() -> void:
	if _current_history and _current_history.changed.is_connected(_auto_save):
		_current_history.changed.disconnect(_auto_save)


# 绑定自动保存（保证幂等：已连接则不重复连）
func _bind_auto_save(p_history: ChatMessageHistory) -> void:
	if not p_history.changed.is_connected(_auto_save):
		p_history.changed.connect(_auto_save)


# 自动保存回调
func _auto_save() -> void:
	save_current_session(_current_history)


# 验证消息完整性
func _validate_message_integrity(p_history: ChatMessageHistory) -> void:
	for msg in p_history.messages:
		if msg.content == null or typeof(msg.content) != TYPE_STRING:
			msg.content = ""
