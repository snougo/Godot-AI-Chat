@tool
extends RefCounted
class_name ChatHistoryManager

# 信号：当会话变更时通知外部
signal session_created(history: ChatMessageHistory, file_path: String)
signal session_loaded(history: ChatMessageHistory, file_path: String)
signal error_occurred(message: String)

# 存档目录常量
const ARCHIVE_DIR = "res://addons/godot_ai_chat/chat_archives/"

# 当前活跃的会话数据
var current_history: ChatMessageHistory
var current_file_path: String = ""

func _init() -> void:
	if not DirAccess.dir_exists_absolute(ARCHIVE_DIR):
		DirAccess.make_dir_recursive_absolute(ARCHIVE_DIR)

# --- 核心会话管理 ---

# 创建新会话
func create_new_session() -> void:
	# 1. 生成基于时间的唯一文件名
	var now = Time.get_datetime_dict_from_system(false)
	var filename = "chat_%d-%02d-%02d_%02d-%02d-%02d.tres" % [now.year, now.month, now.day, now.hour, now.minute, now.second]
	var path = ARCHIVE_DIR.path_join(filename)
	
	# 2. 创建并保存资源
	var new_history = ChatMessageHistory.new()
	var err = ResourceSaver.save(new_history, path)
	
	if err != OK:
		emit_signal("error_occurred", "Failed to create session file: %s" % path)
		return
		
	_set_active_session(new_history, path)
	emit_signal("session_created", new_history, path)


# 加载会话
func load_session(filename: String) -> void:
	var path = ARCHIVE_DIR.path_join(filename)
	if not FileAccess.file_exists(path):
		emit_signal("error_occurred", "File not found: %s" % path)
		return
		
	var history = ResourceLoader.load(path)
	if history is ChatMessageHistory:
		_set_active_session(history, path)
		emit_signal("session_loaded", history, path)
	else:
		emit_signal("error_occurred", "Invalid resource type (not a ChatMessageHistory).")


# --- 辅助功能 (原 ChatArchive) ---

# 获取存档列表
func get_archive_list() -> Array[String]:
	var archives: Array[String] = []
	var dir = DirAccess.open(ARCHIVE_DIR)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and file_name.ends_with(".tres"):
				archives.append(file_name)
			file_name = dir.get_next()
	
	archives.sort()
	archives.reverse() # 最新的在前
	return archives


# 导出当前会话为 Markdown
func export_current_to_markdown(target_path: String) -> bool:
	if not current_history:
		emit_signal("error_occurred", "No active session to export.")
		return false
		
	var md_text = ""
	for msg in current_history.messages:
		if msg.role == ChatMessage.ROLE_SYSTEM: continue
		
		match msg.role:
			ChatMessage.ROLE_USER: md_text += "### 🧑‍💻 User"
			ChatMessage.ROLE_ASSISTANT: md_text += "### 🤖 AI"
			ChatMessage.ROLE_TOOL: md_text += "### ⚙️ Tool (%s)" % msg.name
		
		md_text += "\n\n%s\n\n---\n\n" % msg.content
	
	var file = FileAccess.open(target_path, FileAccess.WRITE)
	if file:
		file.store_string(md_text)
		return true
	else:
		emit_signal("error_occurred", "Failed to write markdown file: %s" % FileAccess.get_open_error())
		return false


# --- 内部私有方法 ---

func _set_active_session(history: ChatMessageHistory, path: String) -> void:
	# 解绑旧的自动保存信号
	if current_history and current_history.changed.is_connected(_auto_save):
		current_history.changed.disconnect(_auto_save)
	
	current_history = history
	current_file_path = path
	
	# 绑定新的自动保存信号
	if not current_history.changed.is_connected(_auto_save):
		current_history.changed.connect(_auto_save)


func _auto_save() -> void:
	if current_history and not current_file_path.is_empty():
		ResourceSaver.save(current_history, current_file_path)
