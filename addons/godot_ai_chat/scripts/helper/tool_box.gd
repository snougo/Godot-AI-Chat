class_name ToolBox
extends RefCounted

## 插件的通用工具箱，包含设置管理、Token 估算、文件系统刷新等辅助功能。

# --- Constants ---

## 插件设置资源文件的固定路径
const SETTINGS_PATH: String = "res://addons/godot_ai_chat/plugin_settings.tres"

# --- Public Functions ---

## 获取插件设置资源。如果文件不存在，则创建一个默认设置文件。
static func get_plugin_settings() -> PluginSettings:
	var _plugin_settings: PluginSettings
	
	if ResourceLoader.exists(SETTINGS_PATH):
		# 使用 CACHE_MODE_IGNORE 确保读取最新设置
		_plugin_settings = ResourceLoader.load(SETTINGS_PATH, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
	else:
		_plugin_settings = PluginSettings.new()
		var _err: Error = ResourceSaver.save(_plugin_settings, SETTINGS_PATH)
		if _err == OK:
			update_editor_filesystem(SETTINGS_PATH)
		else:
			push_error("[Godot AI Chat] Failed to create settings file: %s" % error_string(_err))
	
	return _plugin_settings


## 估算消息列表的 Token 消耗
static func estimate_tokens_for_messages(_messages: Array) -> int:
	# 定义不同字符类型的权重
	const _CHINESE_CHAR_WEIGHT: float = 1.5
	const _OTHER_CHAR_WEIGHT: float = 1.0 / 3.8
	
	var _total_text: String = ""
	for _message in _messages:
		if _message is Dictionary:
			if _message.has("content") and _message.content is String:
				_total_text += _message.content
		elif _message is ChatMessage:
			_total_text += _message.content
	
	if _total_text.is_empty():
		return 0
		
	var _estimated_tokens: float = 0.0
	var _chinese_regex: RegEx = RegEx.create_from_string("[\u4e00-\u9fff]")
	
	# 1. 计算中文字符
	var _chinese_matches: Array[RegExMatch] = _chinese_regex.search_all(_total_text)
	_estimated_tokens += _chinese_matches.size() * _CHINESE_CHAR_WEIGHT
	
	# 2. 计算非中文字符
	var _non_chinese_text: String = _chinese_regex.sub(_total_text, "", true)
	_estimated_tokens += _non_chinese_text.length() * _OTHER_CHAR_WEIGHT
	
	return int(ceil(_estimated_tokens))


## 用于结构化打印聊天历史上下文的调试函数
static func print_structured_context(_title: String, _messages: Array, _context_info: Dictionary = {}) -> void:
	print("\n--- [调试] 上下文报告: %s ---" % _title)
	
	if not _context_info.is_empty():
		for _key in _context_info:
			print("    - %s: %s" % [_key, str(_context_info[_key])])
	
	print("    - 消息总数: %d" % _messages.size())
	print("--- 上下文内容 (角色 | 内容片段) ---")
	
	if _messages.is_empty():
		print("    [上下文为空]")
	else:
		for _i in range(_messages.size()):
			var _msg: Variant = _messages[_i]
			var _role: String = "NO_ROLE"
			var _content: String = "[NO_CONTENT]"
			
			if _msg is Dictionary:
				_role = _msg.get("role", "NO_ROLE")
				_content = str(_msg.get("content", "[NO_CONTENT]"))
			elif _msg is ChatMessage:
				_role = _msg.role
				_content = _msg.content
			
			var _snippet: String = _content.replace("\n", "\\n")
			if _snippet.length() > 100:
				_snippet = _snippet.left(100) + "..."
				
			print("    [%d] 角色: \"%s\" | 内容: \"%s\"" % [_i, _role, _snippet])
	
	print("--- 报告结束 ---\n")


## 检查文件是否已在 ScriptEditor 中打开
static func is_file_open_in_script_editor(_path: String) -> bool:
	var _script_editor: ScriptEditor = EditorInterface.get_script_editor()
	if not _script_editor:
		return false
	
	# 遍历打开的编辑器实例，检查元数据中的文件路径
	for _editor in _script_editor.get_open_script_editors():
		if _editor.has_meta("_edit_res_path") and _editor.get_meta("_edit_res_path") == _path:
			return true
	return false


## 更新指定文件的编辑器文件系统状态
static func update_editor_filesystem(_path: String) -> void:
	if Engine.is_editor_hint():
		var _editor_filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
		if _editor_filesystem:
			_editor_filesystem.update_file(_path)


## 触发编辑器文件系统的完全扫描
static func refresh_editor_filesystem() -> void:
	if Engine.is_editor_hint():
		var _editor_filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
		if _editor_filesystem:
			_editor_filesystem.scan()


## 从 AI 响应中移除 <think>...</think> 标签块
static func remove_think_tags(_text: String) -> String:
	if _text.is_empty():
		return ""
	var _think_regex: RegEx = RegEx.create_from_string("(?s)<think>.*?</think>")
	var _cleaned_text: String = _think_regex.sub(_text, "", true)
	return _cleaned_text.strip_edges()
