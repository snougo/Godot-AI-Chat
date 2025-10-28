extends RefCounted
class_name ToolBox


# 插件设置资源文件的固定路径。
const SETTINGS_PATH: String = "res://addons/godot_ai_chat/plugin_settings.tres"


#==============================================================================
# ## 静态函数 ##
#==============================================================================

static func get_plugin_settings() -> PluginSettings:
	var settings: PluginSettings
	
	if ResourceLoader.exists(SETTINGS_PATH):
		# 如果设置文件存在，则直接加载。
		# 使用 CACHE_MODE_IGNORE 可以确保每次都从磁盘读取最新的设置，
		# 这对于用户在编辑器中修改设置后能立即生效非常重要。
		settings = ResourceLoader.load(SETTINGS_PATH, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
	else:
		# 如果文件不存在，则创建一个新的默认设置对象并保存。
		settings = PluginSettings.new()
		ResourceSaver.save(settings, SETTINGS_PATH)
	
	return settings


static func estimate_tokens_for_messages(messages: Array) -> int:
	# 定义不同字符类型的权重
	# 一个中文字符通常算作 1-2 个 token，我们取一个较高的平均值 1.5
	const CHINESE_CHAR_WEIGHT: float = 1.5
	# 对于英文、数字、空格和标点，我们使用一个较低的权重。
	# 经验值表明，大约 3.5 - 4 个这类字符等于 1 个 token。
	const OTHER_CHAR_WEIGHT: float = 1.0 / 3.8
	
	var total_text: String = ""
	for message in messages:
		if message.has("content") and message.content is String:
			total_text += message.content
	
	if total_text.is_empty():
		return 0
	var estimated_tokens: float = 0.0
	# 使用正则表达式来匹配所有的中文字符
	# Unicode 范围 \u4e00-\u9fff 覆盖了绝大多数常用汉字
	var chinese_regex: RegEx = RegEx.create_from_string("[\u4e00-\u9fff]")
	# 1. 计算所有中文字符的 token 消耗
	var chinese_matches: Array[RegExMatch] = chinese_regex.search_all(total_text)
	estimated_tokens += chinese_matches.size() * CHINESE_CHAR_WEIGHT
	# 2. 将所有中文字符从原文本中移除，剩下的就是英文、数字、符号等
	var non_chinese_text: String = chinese_regex.sub(total_text, "", true)
	# 3. 计算剩余字符的 token 消耗
	estimated_tokens += non_chinese_text.length() * OTHER_CHAR_WEIGHT
	# 向上取整，确保结果是整数且不会低估
	return int(ceil(estimated_tokens))


# 用于结构化打印聊天历史上下文的调试函数
static func print_structured_context(title: String, messages: Array, context_info: Dictionary = {}) -> void:
	print("\n--- [调试] 上下文报告: %s ---" % title)
	
	if not context_info.is_empty():
		for key in context_info:
			print("    - %s: %s" % [key, str(context_info[key])])
	
	print("    - 消息总数: %d" % messages.size())
	print("--- 上下文内容 (角色 | 内容片段) ---")
	
	if messages.is_empty():
		print("    [上下文为空]")
	else:
		for i in range(messages.size()):
			var msg: Dictionary = messages[i]
			var role = msg.get("role", "NO_ROLE")
			var content = str(msg.get("content", "[NO_CONTENT]"))
			
			var snippet = content.replace("\n", "\\n")
			if snippet.length() > 100:
				snippet = snippet.left(100) + "..."
				
			print("    [%d] 角色: \"%s\" | 内容: \"%s\"" % [i, role, snippet])
	
	print("--- 报告结束 ---\n")


# 从长期记忆上下文信息中提取纯净的树状结构
static func extract_folder_tree_from_context(raw_content: String) -> String:
	const MARKER = "Folder File Structure:"
	var start_pos: int = raw_content.find(MARKER)
	
	if start_pos == -1:
		return raw_content
	
	var content_after_marker: String = raw_content.substr(start_pos + MARKER.length())
	
	var cleaned_content: String = content_after_marker.strip_edges()
	cleaned_content = cleaned_content.trim_prefix("```").strip_edges()
	cleaned_content = cleaned_content.trim_suffix("```").strip_edges()
	
	return cleaned_content


static func update_editor_filesystem(_path) -> void:
	if Engine.is_editor_hint():
		var editor_filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
		if editor_filesystem:
			editor_filesystem.update_file(_path)
			print(editor_filesystem.get_file_type(_path))
