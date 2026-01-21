@tool
class_name SessionManager
extends RefCounted

## [Refactor] 核心重构：负责管理聊天会话的生命周期（创建、加载、保存）

# 存档目录
const ARCHIVE_DIR: String = "res://addons/godot_ai_chat/chat_archives/"

# 当前活动的会话路径
var current_history_path: String = ""

# 依赖注入：需要 ChatUI 和 Window 来更新界面和获取数据
var _chat_ui: ChatUI
var _current_chat_window: CurrentChatWindow

func _init(chat_ui: ChatUI, current_chat_window: CurrentChatWindow) -> void:
	_chat_ui = chat_ui
	_current_chat_window = current_chat_window
	_ensure_archive_dir()

# 确保目录存在
func _ensure_archive_dir() -> void:
	if not DirAccess.dir_exists_absolute(ARCHIVE_DIR):
		DirAccess.make_dir_recursive_absolute(ARCHIVE_DIR)

# 创建新会话
# 返回：新创建的文件名，如果失败返回空字符串
func create_new_session() -> String:
	_ensure_archive_dir()
	
	# 文件名生成逻辑
	var _now_time: Dictionary = Time.get_datetime_dict_from_system(false)
	var _base_filename: String = "chat_%d-%02d-%02d_%02d-%02d-%02d" % [_now_time.year, _now_time.month, _now_time.day, _now_time.hour, _now_time.minute, _now_time.second]
	var _extension: String = ".tres"
	var _final_path: String = ARCHIVE_DIR.path_join(_base_filename + _extension)
	
	# 避免重名
	var _counter: int = 1
	while FileAccess.file_exists(_final_path):
		_final_path = ARCHIVE_DIR.path_join("%s_%d%s" % [_base_filename, _counter, _extension])
		_counter += 1
	
	# 创建资源
	var _new_history: ChatMessageHistory = ChatMessageHistory.new()
	var _err: Error = ResourceSaver.save(_new_history, _final_path)
	
	if _err != OK:
		push_error("[SessionManager] Failed to create chat file: %s" % error_string(_err))
		return ""
	
	current_history_path = _final_path
	
	# 刷新编辑器文件系统
	ToolBox.update_editor_filesystem(current_history_path)
	
	# 加载到 UI 并绑定
	_load_resource_to_ui(_new_history, _final_path.get_file())
	
	return _final_path.get_file()

# 加载会话
func load_session(filename: String) -> bool:
	var _path: String = ARCHIVE_DIR.path_join(filename)
	
	if not FileAccess.file_exists(_path):
		return false
	
	var _resource = ResourceLoader.load(_path)
	if _resource is ChatMessageHistory:
		current_history_path = _path
		_load_resource_to_ui(_resource, filename)
		return true
	
	return false

# 检查当前是否有活跃会话
func has_active_session() -> bool:
	return not current_history_path.is_empty()

# [内部] 将资源应用到 UI 并建立自动保存连接
func _load_resource_to_ui(history: ChatMessageHistory, filename: String) -> void:
	_chat_ui.select_archive_by_name(filename)
	_chat_ui.reset_token_cost_display()
	_current_chat_window.load_history_resource(history)
	
	# 绑定自动保存（如果还没绑定）
	# 注意：我们要先断开可能存在的旧连接，防止重复绑定或跨会话污染
	if history.changed.is_connected(_auto_save):
		history.changed.disconnect(_auto_save)
	
	history.changed.connect(_auto_save)

# 自动保存回调
func _auto_save() -> void:
	if current_history_path.is_empty():
		return
	
	# 直接从 Window 获取当前正在使用的资源，确保数据一致性
	var history: ChatMessageHistory = _current_chat_window.chat_history
	if history:
		ResourceSaver.save(history, current_history_path)
