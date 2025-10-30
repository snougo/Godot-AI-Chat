extends RefCounted
class_name ChatArchive


# (原始代码中存在但未使用) 当聊天加载完成时发出。
signal chat_load_finished(chat_history)
# 聊天存档文件存储的固定目录路径。
const ARCHIVE_DIR: String = "res://addons/godot_ai_chat/chat_archives/"
# 新增：聊天总结文件存储的目录路径
const SUMMARY_DIR: String = "res://addons/godot_ai_chat/chat_summaries/"


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 在插件启动时调用，以确保存档目录存在。
static func initialize_archive_directory() -> void:
	# 重命名为更通用的名称
	_ensure_directory_exists(ARCHIVE_DIR)
	_ensure_directory_exists(SUMMARY_DIR)


# 获取存档目录中所有聊天存档（.tres 文件）的文件名列表。
static func get_archive_list() -> Array:
	var archives: Array = []
	var dir: DirAccess = DirAccess.open(ARCHIVE_DIR)
	if dir:
		for file_name in dir.get_files():
			if file_name.ends_with(".tres"):
				archives.append(file_name)
	archives.sort()
	return archives


# 从指定的存档文件名加载聊天历史记录。
static func load_chat_archive_from_file(_archive_name: String) -> PluginChatHistory:
	var path: String = ARCHIVE_DIR.path_join(_archive_name)
	if ResourceLoader.exists(path):
		var resource = ResourceLoader.load(path)
		if resource is PluginChatHistory:
			print("Godot AI Chat: Archive loaded from '%s'" % path)
			return resource
		else:
			push_error("Godot AI Chat: Loaded resource is not a PluginChatHistory at '%s'." % path)
			return null
	else:
		push_error("Godot AI Chat: Failed to load archive at '%s'." % path)
		return null


# 将一个 PluginChatHistory 资源对象保存到文件中。
static func save_current_chat_to_file(_history_resource: PluginChatHistory, _file_path: String) -> bool:
	if not is_instance_valid(_history_resource):
		push_error("Godot AI Chat: Cannot save, provided history resource is invalid.")
		return false
	
	var file_name: String = _file_path.get_file()
	if not file_name.ends_with(".tres"):
		file_name += ".tres"
	
	# 确保存档目录存在
	var global_archive_dir: String = ProjectSettings.globalize_path(ARCHIVE_DIR)
	if not DirAccess.dir_exists_absolute(global_archive_dir):
		var err: Error = DirAccess.make_dir_recursive_absolute(global_archive_dir)
		if err != OK:
			push_error("Godot AI Chat: Failed to create archive directory at '%s'." % ARCHIVE_DIR)
			return false
	
	var path: String = ARCHIVE_DIR.path_join(file_name)
	var err: Error = ResourceSaver.save(_history_resource, path)
	
	if err == OK:
		print("Godot AI Chat: Chat saved to '%s'" % path)
		return true
	else:
		push_error("Godot AI Chat: Failed to save chat to '%s'." % path)
		return false


# 将聊天历史记录数组导出为 Markdown 格式的文件。
static func save_to_markdown(_chat_history: Array, _file_path: String) -> bool:
	var full_chat_text: String = ""
	for i in range(_chat_history.size()):
		var chat_message: Dictionary = _chat_history[i]
		# 跳过第一条系统消息
		if chat_message.role == "system" and i == 0: continue
		
		# 根据角色添加不同的 Markdown 标题
		if chat_message.role == "user": full_chat_text += "### 🧑‍💻 User\n"
		elif chat_message.role == "assistant": full_chat_text += "### 🤖 AI Response\n"
		elif chat_message.role == "tool": full_chat_text += "### ⚙️ Tool Output\n" 
		
		full_chat_text += chat_message.content + "\n\n>------------\n\n"
	
	var file: FileAccess = FileAccess.open(_file_path, FileAccess.WRITE)
	if file:
		file.store_string(full_chat_text)
		return true
	else:
		push_error("Godot AI Chat: Failed to save markdown. Error: %s" % FileAccess.get_open_error())
		return false


# 新增：将总结文本保存为 Markdown 文件
static func save_summary_to_markdown(summary_text: String) -> String:
	var now: Dictionary = Time.get_datetime_dict_from_system(false)
	var timestamp_str: String = "summary_%d-%02d-%02d_%02d-%02d-%02d.md" % [now.year, now.month, now.day, now.hour, now.minute, now.second]
	var file_path: String = SUMMARY_DIR.path_join(timestamp_str)
	
	var file: FileAccess = FileAccess.open(file_path, FileAccess.WRITE)
	if file:
		file.store_string("# Chat Summary\n\n" + summary_text)
		print("Godot AI Chat: Summary saved to '%s'" % file_path)
		return file_path
	else:
		push_error("Godot AI Chat: Failed to save summary. Error: %s" % FileAccess.get_open_error())
		return ""


#==============================================================================
# ## 内部辅助函数 ##
#==============================================================================

# 新增：用于检查并创建目录
static func _ensure_directory_exists(dir_path: String) -> void:
	var global_path: String = ProjectSettings.globalize_path(dir_path)
	if DirAccess.dir_exists_absolute(global_path):
		return
	
	var err: Error = DirAccess.make_dir_recursive_absolute(global_path)
	if err == OK:
		print("Godot AI Chat: Created directory at '%s'." % dir_path)
		if Engine.is_editor_hint():
			EditorInterface.get_resource_filesystem().scan()
	else:
		push_error("Godot AI Chat: Failed to create directory at '%s'. Error: %s" % [dir_path, error_string(err)])
