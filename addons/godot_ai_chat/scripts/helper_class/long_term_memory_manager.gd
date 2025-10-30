extends RefCounted
class_name LongTermMemoryManager

const MEMORY_PATH: String = "res://addons/godot_ai_chat/plugin_long_term_memory.md"
const PARSE_REGEX: String = "(?s)### Path: (.*?)\\s*```(.*?)```"


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 添加一条新的文件夹上下文记忆
static func add_folder_context(path: String, raw_tool_result: String) -> void:
	# 步骤 1: 读取现有记忆以防止重复添加。
	var current_memory: Dictionary = _get_memory_as_dict()
	if current_memory.has(path):
		return
	
	# 步骤 2: 准备要存储的新内容。
	var content_to_store: String = ToolBox.extract_folder_tree_from_context(raw_tool_result)
	if content_to_store.is_empty():
		return
	
	# 步骤 3: 打开文件，将指针移动到末尾，然后写入新条目。
	# _get_memory_as_dict 内部的 _ensure_file_exists 确保了文件此时一定存在。
	var file = FileAccess.open(MEMORY_PATH, FileAccess.READ_WRITE)
	if not is_instance_valid(file):
		push_error("[LongTermMemoryManager] Failed to open memory file for appending.")
		return
	
	# 关键：将文件指针移动到末尾以进行追加
	file.seek_end()
	var new_entry_string: String = "### Path: %s\n```\n%s\n```\n\n---\n\n" % [path, content_to_store]
	file.store_string(new_entry_string)
	
	# 步骤 4: 独立地通知编辑器文件已更新。
	ToolBox.update_editor_filesystem(MEMORY_PATH)


# 获取所有已记忆的文件夹上下文
static func get_all_folder_context() -> Dictionary:
	var long_term_memory_dict: Dictionary = _get_memory_as_dict()
	# 独立地通知编辑器
	ToolBox.update_editor_filesystem(MEMORY_PATH)
	return long_term_memory_dict


#==============================================================================
# ## 内部辅助函数 ##
#==============================================================================

# 确保文件存在。如果不存在，则独立地创建一个最小化的空文件。
static func _ensure_file_exists() -> void:
	if not FileAccess.file_exists(MEMORY_PATH):
		var file = FileAccess.open(MEMORY_PATH, FileAccess.WRITE)
		if not is_instance_valid(file):
			push_error("[LongTermMemoryManager] Failed to create new memory file at %s." % MEMORY_PATH)
			return
		
		# 只写入最基本的内容
		file.store_string("# Godot AI Chat - Long-Term Memory\n\n")
		# 独立地通知编辑器
		ToolBox.update_editor_filesystem(MEMORY_PATH)


# 将一个字典的完整内容序列化并覆盖写入到文件中。
static func _save_memory_from_dict(memory_dict: Dictionary) -> void:
	var content_string: String = "# Godot AI Chat - Long-Term Memory\n\n"
	
	var sorted_paths = memory_dict.keys()
	sorted_paths.sort()
	
	for path in sorted_paths:
		var folder_structure = memory_dict[path]
		content_string += "### Path: %s\n```\n%s\n```\n\n---\n\n" % [path, folder_structure]
		
	var file = FileAccess.open(MEMORY_PATH, FileAccess.WRITE)
	if not is_instance_valid(file):
		push_error("[LongTermMemoryManager] Failed to open memory file for writing.")
		return
	
	file.store_string(content_string)
	# 独立地通知编辑器
	ToolBox.update_editor_filesystem(MEMORY_PATH)


# 从文件中读取内容并解析为字典。
static func _get_memory_as_dict() -> Dictionary:
	# 在执行任何读取操作前，先确保文件存在。
	_ensure_file_exists()
	
	var memory_dict: Dictionary = {}
	var file = FileAccess.open(MEMORY_PATH, FileAccess.READ)
	if not is_instance_valid(file):
		push_error("[LongTermMemoryManager] Failed to open memory file for reading.")
		return memory_dict
	
	var content: String = file.get_as_text()
	var regex: RegEx = RegEx.create_from_string(PARSE_REGEX)
	var matches = regex.search_all(content)
	
	for match in matches:
		var path: String = match.get_string(1).strip_edges()
		var stored_content: String = match.get_string(2).strip_edges()
		if not path.is_empty():
			memory_dict[path] = stored_content
	
	return memory_dict
