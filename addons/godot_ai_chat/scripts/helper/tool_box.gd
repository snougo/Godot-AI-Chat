class_name ToolBox
extends RefCounted

## 通用工具箱
##
## 包含设置管理、Token 估算、文件系统刷新等辅助功能。

# --- Constants ---

## 插件设置资源文件的固定路径
const SETTINGS_PATH: String = "res://addons/godot_ai_chat/plugin_settings.tres"

# --- Public Functions ---

## 获取插件设置资源。如果文件不存在，则创建一个默认设置文件。
static func get_plugin_settings() -> PluginSettings:
	var plugin_settings: PluginSettings
	
	if ResourceLoader.exists(SETTINGS_PATH):
		# 使用 CACHE_MODE_IGNORE 确保读取最新设置
		plugin_settings = ResourceLoader.load(SETTINGS_PATH, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
	else:
		plugin_settings = PluginSettings.new()
		var err: Error = ResourceSaver.save(plugin_settings, SETTINGS_PATH)
		if err == OK:
			update_editor_filesystem(SETTINGS_PATH)
		else:
			push_error("[Godot AI Chat] Failed to create settings file: %s" % error_string(err))
	
	return plugin_settings


## 估算消息列表的 Token 消耗
static func estimate_tokens_for_messages(p_messages: Array) -> int:
	# 定义不同字符类型的权重
	const CHINESE_CHAR_WEIGHT: float = 1.5
	const OTHER_CHAR_WEIGHT: float = 1.0 / 3.8
	
	var total_text: String = ""
	for message in p_messages:
		if message is Dictionary:
			if message.has("content") and message.content is String:
				total_text += message.content
		elif message is ChatMessage:
			total_text += message.content
	
	if total_text.is_empty():
		return 0
		
	var estimated_tokens: float = 0.0
	var chinese_regex: RegEx = RegEx.create_from_string("[\u4e00-\u9fff]")
	
	# 1. 计算中文字符
	var chinese_matches: Array[RegExMatch] = chinese_regex.search_all(total_text)
	estimated_tokens += chinese_matches.size() * CHINESE_CHAR_WEIGHT
	
	# 2. 计算非中文字符
	var non_chinese_text: String = chinese_regex.sub(total_text, "", true)
	estimated_tokens += non_chinese_text.length() * OTHER_CHAR_WEIGHT
	
	return int(ceil(estimated_tokens))


## 用于结构化打印聊天历史上下文的调试函数
static func print_structured_context(p_title: String, p_messages: Array, p_context_info: Dictionary = {}) -> void:
	AIChatLogger.debug("\n--- [调试] 上下文报告: %s ---" % p_title)
	
	if not p_context_info.is_empty():
		for key in p_context_info:
			AIChatLogger.debug("    - %s: %s" % [key, str(p_context_info[key])])
	
	AIChatLogger.debug("    - 消息总数: %d" % p_messages.size())
	AIChatLogger.debug("--- 上下文内容 (角色 | 内容片段) ---")
	
	if p_messages.is_empty():
		AIChatLogger.debug("    [上下文为空]")
	else:
		for i in range(p_messages.size()):
			var msg: Variant = p_messages[i]
			var role: String = "NO_ROLE"
			var content: String = "[NO_CONTENT]"
			
			if msg is Dictionary:
				role = msg.get("role", "NO_ROLE")
				content = str(msg.get("content", "[NO_CONTENT]"))
			elif msg is ChatMessage:
				role = msg.role
				content = msg.content
			
			var snippet: String = content.replace("\n", "\\n")
			if snippet.length() > 100:
				snippet = snippet.left(100) + "..."
				
			AIChatLogger.debug("    [%d] 角色: \"%s\" | 内容: \"%s\"" % [i, role, snippet])
	
	AIChatLogger.debug("--- 报告结束 ---\n")


## 检查文件是否已在 ScriptEditor 中打开
static func is_file_open_in_script_editor(p_path: String) -> bool:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if not script_editor:
		return false
	
	# 遍历打开的编辑器实例，检查元数据中的文件路径
	for editor in script_editor.get_open_script_editors():
		if editor.has_meta("_edit_res_path") and editor.get_meta("_edit_res_path") == p_path:
			return true
	return false


## 更新指定文件的编辑器文件系统状态
static func update_editor_filesystem(p_path: String) -> void:
	if Engine.is_editor_hint():
		var editor_filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
		if editor_filesystem:
			editor_filesystem.update_file(p_path)


## 触发编辑器文件系统的完全扫描
static func refresh_editor_filesystem() -> void:
	if Engine.is_editor_hint():
		var editor_filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
		if editor_filesystem:
			editor_filesystem.scan()


## 从 AI 响应中移除 <think>...</think> 标签块
static func remove_think_tags(p_text: String) -> String:
	if p_text.is_empty():
		return ""
	var think_regex: RegEx = RegEx.create_from_string("(?s)<think>.*?</think>")
	var cleaned_text: String = think_regex.sub(p_text, "", true)
	return cleaned_text.strip_edges()


## 过滤掉那些在 <think> 标签尚未闭合时产生的工具调用
static func filter_hallucinated_tool_calls(p_content: String, p_tool_calls: Array) -> Array:
	if p_tool_calls.is_empty() or "<think>" not in p_content:
		return p_tool_calls
	
	var think_start: int = p_content.find("<think>")
	var think_end: int = p_content.find("</think>")
	
	# 如果找到了 <think> 但没找到 </think>，说明思考过程尚未结束
	# 此时产生的所有工具调用都应视为不稳定或幻觉，予以拦截
	if think_start != -1 and think_end == -1:
		AIChatLogger.debug("[ToolBox] Intercepted %d tool calls during unclosed <think> block." % p_tool_calls.size())
		return []
	
	# 如果 <think> 已闭合，或者是其他情况，则认为工具调用是安全的（思考后的产物）
	# 直接放行，不再做内容匹配（防止误杀）
	return p_tool_calls
