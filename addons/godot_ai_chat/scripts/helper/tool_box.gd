@tool
class_name ToolBox
extends RefCounted

## 通用工具箱
##
## 包含设置管理、Token 估算、文件系统刷新等辅助功能。

# --- Static Variables for Debouncing ---
static var _scan_pending: bool = false
static var _scan_delay_ms: int = 100  # 延迟 100ms 执行


# --- Public Functions ---

## 获取插件设置资源。如果文件不存在，则创建一个默认设置文件。
static func get_plugin_settings() -> PluginSettingsConfig:
	var plugin_settings: PluginSettingsConfig
	
	if ResourceLoader.exists(PluginPaths.SETTINGS_PATH):
		# 使用 CACHE_MODE_IGNORE 确保读取最新设置
		plugin_settings = ResourceLoader.load(PluginPaths.SETTINGS_PATH, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
	else:
		plugin_settings = PluginSettingsConfig.new()
		var err: Error = ResourceSaver.save(plugin_settings, PluginPaths.SETTINGS_PATH)
		if err == OK:
			update_editor_filesystem(PluginPaths.SETTINGS_PATH)
		else:
			AIChatLogger.error("[Godot AI Chat] Failed to create settings file: %s" % error_string(err))
	
	return plugin_settings


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


## 更新指定文件的编辑器文件系统状态（增量更新，安全）
static func update_editor_filesystem(p_path: String) -> void:
	if Engine.is_editor_hint():
		var editor_filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
		if editor_filesystem:
			editor_filesystem.update_file(p_path)


## 触发编辑器文件系统的完全扫描（延迟+节流，防崩溃）
static func refresh_editor_filesystem() -> void:
	if not Engine.is_editor_hint():
		return
	
	# 节流：如果已有待执行的扫描，跳过本次
	if _scan_pending:
		AIChatLogger.warn("[ToolBox] Scan already pending, skipping duplicate request.")
		return
	
	_scan_pending = true
	
	# 延迟执行，避免与当前帧的其他文件操作冲突
	var timer: SceneTreeTimer = Engine.get_main_loop().create_timer(_scan_delay_ms / 1000.0)
	timer.timeout.connect(_perform_scan, ConnectFlags.CONNECT_ONE_SHOT)


## 从 AI 响应中移除  thinking... response 标签块
static func remove_think_tags(p_text: String) -> String:
	if p_text.is_empty():
		return ""
	var think_regex: RegEx = RegEx.create_from_string("(?s) thinking.*? response")
	var cleaned_text: String = think_regex.sub(p_text, "", true)
	return cleaned_text.strip_edges()


## 过滤掉那些在 thinking 标签尚未闭合时产生的工具调用
static func filter_hallucinated_tool_calls(p_content: String, p_tool_calls: Array) -> Array:
	if p_tool_calls.is_empty():
		return p_tool_calls
	
	# 同时检测 <think> 和  thinking 两种格式
	var has_think_open: bool = "<think>" in p_content or " thinking" in p_content
	if not has_think_open:
		return p_tool_calls
	
	# 查找 thinking 开始位置（支持两种格式）
	var think_start: int = p_content.find(" thinking")
	if think_start == -1:
		think_start = p_content.find("<think>")
	
	# 查找闭合位置（支持两种格式）
	var think_end: int = p_content.find(" response")
	if think_end == -1:
		think_end = p_content.find("</think>")
	
	# 如果找到了 thinking 开始但没找到闭合 → 思考未结束，全部拦截
	if think_start != -1 and think_end == -1:
		AIChatLogger.warn("[ToolBox] Intercepted %d tool calls during unclosed thinking block." % p_tool_calls.size())
		return []
	
	# thinking 已闭合 → 放行
	return p_tool_calls


## 验证工具名称是否有效
static func is_valid_tool_name(p_name: String) -> bool:
	# 1. 不能为空
	if p_name.is_empty():
		return false
	# 2. 长度不超过 64 字符
	if p_name.length() > 64:
		return false
	# 检查是否包含换行符或特殊字符（明显是代码片段）
	if "\n" in p_name or "(" in p_name or ")" in p_name:
		return false
	# 必须符合函数命名规范
	var regex := RegEx.create_from_string("^[a-zA-Z][a-zA-Z0-9_-]*$")
	
	return regex.search(p_name) != null


## 清洗、过滤工具调用，并将被服务端误判的纯文本"抢救"回消息内容中
static func salvage_and_clean_tool_calls(p_msg: ChatMessage, p_valid_tools: Dictionary = {}) -> void:
	# 防御：确保 ToolRegistry 已初始化
	if ToolRegistry.main_agent_tools.is_empty():
		ToolRegistry.load_default_tools()
	
	var valid_calls: Array = []
	var salvaged_text: String = ""
	
	for tc in p_msg.tool_calls:
		var raw_name: String = tc.get("function", {}).get("name", "")
		var args: String = tc.get("function", {}).get("arguments", "")
		
		# Step 1: 检测 XML 伪标签
		var extract_result: Dictionary = _extract_from_xml_wrapper(raw_name)
		var clean_name: String = extract_result.clean_name
		
		# Step 2: 判断工具合法性
		#   子Agent路径 → 使用自己的 _sub_agent_tools 字典精确校验
		#   主Agent路径 → 使用核心工具集校验
		var is_valid := false
		if not clean_name.is_empty():
			if not p_valid_tools.is_empty():
				is_valid = p_valid_tools.has(clean_name)
			else:
				is_valid = ToolRegistry.main_agent_tools.has(clean_name)
		
		if is_valid:
			# 合法工具：更新清洗后的名称，补充 ID
			tc.function["name"] = clean_name
			if tc.get("id", "").is_empty():
				tc["id"] = "call_%d" % Time.get_ticks_msec()
			valid_calls.append(tc)
		else:
			# 伪工具调用 → 抢救回 content
			AIChatLogger.warn("[ToolBox] Salvaging pseudo tool call: \"%s\"" % raw_name)
			if not salvaged_text.is_empty():
				salvaged_text += "\n"
			salvaged_text += _restore_text(raw_name, args)
	
	p_msg.tool_calls = valid_calls
	
	if not salvaged_text.is_empty():
		if not p_msg.content.ends_with("\n") and not p_msg.content.is_empty():
			p_msg.content += "\n"
		p_msg.content += salvaged_text


# --- Private Functions ---

# 从 raw_name 中检测并提取 XML 伪标签
# 处理服务端懒惰解析场景：<tool_call>xxx（无闭合）、xxx</tool_call>、完整闭合等
# [return]: {"clean_name": String, "has_xml_wrapper": bool}
static func _extract_from_xml_wrapper(p_raw_name: String) -> Dictionary:
	var result := {
		"clean_name": p_raw_name,
		"has_xml_wrapper": false
	}
	
	# 检测开放标签前缀（服务端看到 <tool_call> 就懒惰解析的典型场景）
	var open_patterns: Array[String] = ["<tool_call>", "<function_call>", "<function>"]
	for pattern in open_patterns:
		if p_raw_name.begins_with(pattern):
			result.has_xml_wrapper = true
			result.clean_name = p_raw_name.substr(pattern.length())
			break
	
	# 检测闭合标签后缀（即使前面没有开放标签，仅后缀也算伪信号）
	var close_patterns: Array[String] = ["</tool_call>", "</function_call>", "</function>"]
	for pattern in close_patterns:
		if result.clean_name.ends_with(pattern):
			result.has_xml_wrapper = true
			result.clean_name = result.clean_name.left(-pattern.length())
			break
	
	result.clean_name = result.clean_name.strip_edges()
	return result


# 将伪工具调用的 raw_name 和 args 还原为可读文本
# 根据内容形态选择还原策略：JSON 格式化、自然文本拼接等
static func _restore_text(p_raw_name: String, p_args: String) -> String:
	var text: String = p_raw_name
	if not p_args.is_empty():
		if p_args.begins_with("{") or p_args.begins_with("["):
			var parsed: Variant = JSON.parse_string(p_args)
			if parsed != null:
				text += "\n" + JSON.stringify(parsed, "  ")
			else:
				text += "\n" + p_args
		else:
			if not p_args.begins_with("\n") and not p_args.begins_with(" "):
				text += " "
			text += p_args
	return text


# 内部：实际执行扫描
static func _perform_scan() -> void:
	_scan_pending = false
	
	if not Engine.is_editor_hint():
		return
	
	var editor_filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if editor_filesystem:
		AIChatLogger.debug("[ToolBox] Performing deferred filesystem scan...")
		editor_filesystem.scan()
