extends RefCounted
class_name LongTermMemoryManager

const MEMORY_PATH: String = "res://addons/godot_ai_chat/plugin_long_term_memory.md"
const PARSE_REGEX: String = "(?s)### Path: (.*?)\\s*```(.*?)```"


#==============================================================================
# ## 内部辅助静态函数 ##
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


#==============================================================================
# ## 静态函数 ##
#==============================================================================

# 添加一条新的文件夹上下文记忆
static func add_folder_context(path: String, raw_tool_result: String) -> void:
	# 遵循健壮的“读取-修改-写入”模式
	var current_memory: Dictionary = _get_memory_as_dict()
	# 如果已经有了相同路径的文件夹上下文内容直接退出
	if current_memory.has(path):
		return
	# 如果该路径上的文件夹上下文内容在长期记忆中不存在则进行添加
	var content_to_store: String = ToolBox.extract_folder_tree_from_context(raw_tool_result)
	current_memory[path] = content_to_store
	
	_save_memory_from_dict(current_memory)


# 获取所有已记忆的文件夹上下文
static func get_all_folder_context() -> Dictionary:
	var long_term_memory_dict: Dictionary = _get_memory_as_dict()
	# 独立地通知编辑器
	ToolBox.update_editor_filesystem(MEMORY_PATH)
	return long_term_memory_dict
