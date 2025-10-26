extends RefCounted
class_name LongTermMemoryManager

const MEMORY_PATH: String = "res://addons/godot_ai_chat/plugin_long_term_memory.tres"


#==============================================================================
# ## 内部辅助函数 ##
#==============================================================================

# 负责按需加载或创建资源实例，并确保总是从磁盘读取最新版本。
static func _get_memory_instance() -> PluginLongTermMemory:
	var memory_instance: PluginLongTermMemory
	
	if ResourceLoader.exists(MEMORY_PATH):
		# 使用 CACHE_MODE_IGNORE 强制从磁盘重新加载，忽略Godot的内部缓存。
		memory_instance = ResourceLoader.load(MEMORY_PATH, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
	else:
		# 如果文件不存在，则创建一个新的实例并立即保存它。
		memory_instance = PluginLongTermMemory.new()
		var err: Error = ResourceSaver.save(memory_instance, MEMORY_PATH)
		if err != OK:
			push_error("[LongTermMemoryManager] Failed to create new memory file at %s." % MEMORY_PATH)
			
	return memory_instance


#==============================================================================
# ## 公共静态函数 ##
#==============================================================================

# 添加一条新的文件夹上下文记忆并立即保存
static func add_folder_context(path: String, content: String) -> void:
	# 1. 获取最新的资源实例
	var memory = _get_memory_instance()
	if not is_instance_valid(memory): return
	
	# 2. 安全地修改内容（复制-修改-替换模式）
	var memory_dict_copy = memory.folder_context_memory.duplicate()
	memory_dict_copy[path] = content
	memory.folder_context_memory = memory_dict_copy
	
	# 3. 将修改后的资源保存回磁盘
	var error = ResourceSaver.save(memory, MEMORY_PATH)
	
	# 4. 通知编辑器文件系统更新 (新增修复)
	if error == OK and Engine.is_editor_hint():
		var editor_filesystem = EditorInterface.get_resource_filesystem()
		if editor_filesystem:
			# 这个调用会告诉编辑器立即从磁盘重新加载该文件
			editor_filesystem.update_file(MEMORY_PATH)


# 获取所有已记忆的文件夹上下文
static func get_all_folder_context() -> Dictionary:
	# 每次调用都从磁盘获取最新的资源实例
	var memory = _get_memory_instance()
	if is_instance_valid(memory):
		# 返回一个副本以防止外部修改影响原始数据
		return memory.folder_context_memory.duplicate(true)
	
	return {}
