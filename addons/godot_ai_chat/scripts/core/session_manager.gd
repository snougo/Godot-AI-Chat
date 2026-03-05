@tool
class_name SessionManager
extends RefCounted

## 会话管理器
##
## 负责聊天会话的创建、加载、删除和自动保

# --- Public Vars ---

var current_session_path: String = ""


# --- Public Functions ---

## 创建新会话
## [return]: 新创建的历史记录对象，失败返回 null
func create_new_session() -> ChatMessageHistory:
	_ensure_archive_dir()
	var now: Dictionary = Time.get_datetime_dict_from_system(false)
	var base_filename: String = "chat_%d-%02d-%02d_%02d-%02d-%02d" %[now.year, now.month, now.day, now.hour, now.minute, now.second]
	var extension: String = ".tres"
	var final_path: String = PluginPaths.SESSION_DIR.path_join(base_filename + extension)
	
	var counter: int = 1
	while FileAccess.file_exists(final_path):
		final_path = PluginPaths.SESSION_DIR.path_join("%s_%d%s" % [base_filename, counter, extension])
		counter += 1
	
	var new_history: ChatMessageHistory = ChatMessageHistory.new()
	if ResourceSaver.save(new_history, final_path) == OK:
		current_session_path = final_path
		ToolBox.update_editor_filesystem(current_session_path)
		_bind_auto_save(new_history)
		return new_history
	
	AIChatLogger.error("[SessionManager] Failed to create chat file.")
	return null


## 加载会话
## [param p_session_name]: 会话文件名
## [return]: 加载的历史记录对象，失败返回 null
func load_session(p_session_name: String) -> ChatMessageHistory:
	var path: String = PluginPaths.SESSION_DIR.path_join(p_session_name)
	if FileAccess.file_exists(path):
		var resource = ResourceLoader.load(path)
		if resource is ChatMessageHistory:
			current_session_path = path
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
			current_session_path = ""
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

# 确保存档目录存在
func _ensure_archive_dir() -> void:
	if not DirAccess.dir_exists_absolute(PluginPaths.SESSION_DIR):
		DirAccess.make_dir_recursive_absolute(PluginPaths.SESSION_DIR)


# 绑定自动保存
func _bind_auto_save(history: ChatMessageHistory) -> void:
	if history.changed.is_connected(_auto_save):
		history.changed.disconnect(_auto_save)
	history.changed.connect(_auto_save.bind(history))


# 自动保存回调
func _auto_save(history: ChatMessageHistory) -> void:
	save_current_session(history)


# 验证消息完整性
func _validate_message_integrity(p_history: ChatMessageHistory) -> void:
	for msg in p_history.messages:
		if msg.content == null or typeof(msg.content) != TYPE_STRING:
			msg.content = ""
