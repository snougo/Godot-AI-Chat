@tool
class_name SessionManager
extends RefCounted

## 会话管理器
##
## 负责管理聊天会话的生命周期（创建、加载、保存）。

# --- Constants ---

## 存档目录
const ARCHIVE_DIR: String = "res://addons/godot_ai_chat/chat_archives/"

# --- Public Vars ---

## 当前活动的会话路径
var current_history_path: String = ""

# --- Private Vars ---

# 依赖注入：需要 ChatUI 和 Window 来更新界面和获取数据
var _chat_ui: ChatUI
var _current_chat_window: CurrentChatWindow


# --- Built-in Functions ---

func _init(p_chat_ui: ChatUI, p_current_chat_window: CurrentChatWindow) -> void:
	_chat_ui = p_chat_ui
	_current_chat_window = p_current_chat_window
	_ensure_archive_dir()


# --- Public Functions ---

## 创建新会话
## 返回：新创建的文件名，如果失败返回空字符串
func create_new_session() -> String:
	_ensure_archive_dir()
	
	# 文件名生成逻辑
	var now_time: Dictionary = Time.get_datetime_dict_from_system(false)
	var base_filename: String = "chat_%d-%02d-%02d_%02d-%02d-%02d" % [now_time.year, now_time.month, now_time.day, now_time.hour, now_time.minute, now_time.second]
	var extension: String = ".tres"
	var final_path: String = ARCHIVE_DIR.path_join(base_filename + extension)
	
	# 避免重名
	var counter: int = 1
	while FileAccess.file_exists(final_path):
		final_path = ARCHIVE_DIR.path_join("%s_%d%s" % [base_filename, counter, extension])
		counter += 1
	
	# 创建资源
	var new_history: ChatMessageHistory = ChatMessageHistory.new()
	var err: Error = ResourceSaver.save(new_history, final_path)
	
	if err != OK:
		push_error("[SessionManager] Failed to create chat file: %s" % error_string(err))
		return ""
	
	current_history_path = final_path
	
	# 刷新编辑器文件系统
	ToolBox.update_editor_filesystem(current_history_path)
	
	# 加载到 UI 并绑定
	_load_resource_to_ui(new_history, final_path.get_file())
	
	return final_path.get_file()


## 加载会话
func load_session(p_filename: String) -> bool:
	var path: String = ARCHIVE_DIR.path_join(p_filename)
	
	if not FileAccess.file_exists(path):
		return false
	
	var resource = ResourceLoader.load(path)
	if resource is ChatMessageHistory:
		current_history_path = path
		_load_resource_to_ui(resource, p_filename)
		return true
	
	return false


## 删除指定会话并返回是否成功
func delete_session(p_filename: String) -> bool:
	var archive_path: String = ARCHIVE_DIR.path_join(p_filename)
	
	# 检查文件是否存在
	if not FileAccess.file_exists(archive_path):
		push_error("[SessionManager] Archive file not found: %s" % p_filename)
		return false
	
	# 删除文件
	var err: Error = DirAccess.remove_absolute(archive_path)
	if err != OK:
		push_error("[SessionManager] Failed to delete archive: %s" % error_string(err))
		return false
	
	# 如果删除的是当前会话，清除当前会话状态
	if current_history_path == archive_path:
		current_history_path = ""
		_current_chat_window.chat_history = null
		# 清空聊天显示
		for child in _current_chat_window.chat_list_container.get_children():
			child.queue_free()
	
	# 刷新编辑器文件系统
	ToolBox.update_editor_filesystem(archive_path)
	return true


## 加载最新可用的会话
## 返回：加载的会话文件名，如果没有可用会话返回空字符串
func load_latest_session() -> String:
	var archive_list := ChatArchive.get_archive_list()
	
	if archive_list.is_empty():
		return ""
	
	var latest_archive = archive_list[0]
	var success: bool = load_session(latest_archive)
	
	if success:
		return latest_archive
	else:
		push_error("[SessionManager] Failed to load latest session: %s" % latest_archive)
		return ""


## 检查当前是否有活跃会话
func has_active_session() -> bool:
	return not current_history_path.is_empty()


# --- Private Functions ---

## 确保目录存在
func _ensure_archive_dir() -> void:
	if not DirAccess.dir_exists_absolute(ARCHIVE_DIR):
		DirAccess.make_dir_recursive_absolute(ARCHIVE_DIR)


## [内部] 将资源应用到 UI 并建立自动保存连接
func _load_resource_to_ui(p_history: ChatMessageHistory, p_filename: String) -> void:
	_chat_ui.select_archive_by_name(p_filename)
	_chat_ui.reset_token_cost_display()
	_current_chat_window.load_history_resource(p_history)
	
	# 绑定自动保存（如果还没绑定）
	# 注意：我们要先断开可能存在的旧连接，防止重复绑定或跨会话污染
	if p_history.changed.is_connected(_auto_save):
		p_history.changed.disconnect(_auto_save)
	
	p_history.changed.connect(_auto_save)


## 自动保存回调
func _auto_save() -> void:
	if current_history_path.is_empty():
		return
	
	# 直接从 Window 获取当前正在使用的资源，确保数据一致性
	var history: ChatMessageHistory = _current_chat_window.chat_history
	if history:
		# [修复] 验证所有消息的完整性
		_validate_message_integrity(history)
		ResourceSaver.save(history, current_history_path)


## 验证并修复消息完整性
func _validate_message_integrity(p_history: ChatMessageHistory) -> void:
	for msg in p_history.messages:
		# 确保 content 字段不为 null
		if msg.content == null or typeof(msg.content) != TYPE_STRING:
			msg.content = ""
