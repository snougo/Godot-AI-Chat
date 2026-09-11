@tool
class_name ToolBox
extends RefCounted

## 通用工具箱
##
## 包含设置管理、文件系统刷新、JSON 安全序列化与工具调用清洗等辅助功能。


# --- Constants ---

## 文件系统全量扫描的延迟执行时间（毫秒），用于节流与防重入
const SCAN_DELAY_MSEC: int = 100


# --- Static Vars ---

## 是否有待执行的定时扫描
static var _scan_pending: bool = false
## 控制字符检测正则（懒加载缓存）
static var _control_char_regex: RegEx = null
## 工具名合法性校验正则（懒加载缓存）
static var _tool_name_regex: RegEx = null


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


## 在 Shader Editor 中查找编辑指定 shader 的 CodeEdit。
## 通过内容匹配定位（Shader Editor 的 CodeEdit buffer 与 shader.get_code() 实时同步），
## 找到后自动激活对应标签。若目标 shader 未在 Shader Editor 打开，返回 null。
## 注意：内容匹配在"两个不同 shader 内容完全相同"时会命中第一个，属已知边界情况。
static func find_shader_code_edit(p_shader: Shader) -> CodeEdit:
	if p_shader == null:
		return null
	var root: Node = EditorInterface.get_base_control()
	for node: Node in root.find_children("*", "TextShaderEditor", true, false):
		var code_edits: Array = node.find_children("*", "CodeEdit", true, false)
		if code_edits.is_empty():
			continue
		var code_edit: CodeEdit = code_edits[0] as CodeEdit
		if code_edit == null:
			continue
		# 优先：身份匹配（CodeEdit 的父节点即 ShaderTextEditor，可获取编辑的 shader 资源）
		var parent: Object = code_edit.get_parent()
		if parent != null and parent.has_method("get_edited_shader") \
				and parent.get_edited_shader() == p_shader:
			_activate_shader_tab(node)
			return code_edit
		# 兜底：内容匹配（仅当身份匹配不可用时）
		if code_edit.text == p_shader.get_code():
			_activate_shader_tab(node)
			return code_edit
	return null


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
	_schedule_deferred_scan()


## 安全序列化 JSON：将 JSON.stringify 输出中未被转义的控制字符（0x00-0x1F）
## 统一转义为 \uXXXX。Godot 的 JSON.stringify 不会转义这些字符，会生成非法 JSON，
## 导致 OpenAI/Anthropic 等严格校验的 API 返回 400 (control character found)。
##
## [性能] 旧实现用 `out += json_str[i]` 逐字符拼接，在 GDScript 中每次 += 都会
## 复制整个已累积字符串（O(n²)）。实测含图片 base64 的 3.65 MB 请求体需 448 秒，
## 远超网络超时预算，会被误报为 "Connection timeout"。
## 现改为：
## 1) C++ 层 RegEx 预检，无控制字符直接返回原串（base64 图片必走此路径）；
## 2) 慢路径按"连续片段"整块拷贝，仅对控制字符转义，整体 O(n)。
static func stringify_json_safe(p_value: Variant) -> String:
	var json_str: String = JSON.stringify(p_value)
	
	if _control_char_regex == null:
		_control_char_regex = RegEx.create_from_string("[\\x00-\\x1f]")
	if _control_char_regex.search(json_str) == null:
		return json_str
	
	var total: int = json_str.length()
	var parts: PackedStringArray = PackedStringArray()
	var run_start: int = 0
	for i: int in total:
		var cp: int = json_str.unicode_at(i)
		if cp >= 0x20:
			continue
		if i > run_start:
			parts.append(json_str.substr(run_start, i - run_start))
		parts.append("\\u%04X" % cp)
		run_start = i + 1
	if run_start < total:
		parts.append(json_str.substr(run_start))
	return "".join(parts)


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
	if _tool_name_regex == null:
		_tool_name_regex = RegEx.create_from_string("^[a-zA-Z][a-zA-Z0-9_-]*$")
	
	return _tool_name_regex.search(p_name) != null


## 清洗、过滤工具调用，并将被服务端误判的纯文本"抢救"回消息内容中
## [param p_msg]: 待清洗的助手消息（会被原地修改）
## [param p_valid_tools]: 可选的合法工具表；为空时使用 Main-Agent 核心工具集校验
static func salvage_and_clean_tool_calls(p_msg: ChatMessage, p_valid_tools: Dictionary = {}) -> void:
	# 防御：确保 ToolRegistry 已初始化
	if ToolRegistry.main_agent_tools.is_empty():
		ToolRegistry.load_default_tools()
	
	var valid_calls: Array = []
	var salvaged_text: String = ""
	
	for raw_call: Variant in p_msg.tool_calls:
		if not raw_call is Dictionary:
			continue
		var tc: Dictionary = raw_call
		
		var func_dict: Dictionary = tc.get("function", {})
		var raw_name: String = String(func_dict.get("name", ""))
		var args: String = String(func_dict.get("arguments", ""))
		
		# Step 1: 检测 XML 伪标签
		var extract_result: Dictionary = _extract_from_xml_wrapper(raw_name)
		var clean_name: String = String(extract_result.clean_name)
		
		# Step 2: 判断工具合法性
		#   子Agent路径 → 使用自己的 _sub_agent_tools 字典精确校验
		#   主Agent路径 → 使用核心工具集校验
		var is_valid: bool = false
		if not clean_name.is_empty():
			if not p_valid_tools.is_empty():
				is_valid = p_valid_tools.has(clean_name)
			else:
				is_valid = ToolRegistry.main_agent_tools.has(clean_name)
		
		if is_valid:
			# 合法工具：更新清洗后的名称，补充 ID
			func_dict["name"] = clean_name
			if String(tc.get("id", "")).is_empty():
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
# [param p_raw_name]: 原始工具名
# [return]: {"clean_name": String, "has_xml_wrapper": bool}
static func _extract_from_xml_wrapper(p_raw_name: String) -> Dictionary:
	var result: Dictionary = {
		"clean_name": p_raw_name,
		"has_xml_wrapper": false
	}
	
	# 检测开放标签前缀（服务端看到 <tool_call> 就懒惰解析的典型场景）
	var open_patterns: Array[String] = ["<tool_call>", "<function_call>", "<function>"]
	for pattern: String in open_patterns:
		if p_raw_name.begins_with(pattern):
			result["has_xml_wrapper"] = true
			result["clean_name"] = p_raw_name.substr(pattern.length())
			break
	
	# 检测闭合标签后缀（即使前面没有开放标签，仅后缀也算伪信号）
	var close_patterns: Array[String] = ["</tool_call>", "</function_call>", "</function>"]
	for pattern: String in close_patterns:
		var current: String = String(result["clean_name"])
		if current.ends_with(pattern):
			result["has_xml_wrapper"] = true
			result["clean_name"] = current.left(-pattern.length())
			break
	
	result["clean_name"] = String(result["clean_name"]).strip_edges()
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


# 内部：延迟调度扫描
static func _schedule_deferred_scan() -> void:
	if not Engine.is_editor_hint():
		_scan_pending = false
		return
	
	var timer: SceneTreeTimer = Engine.get_main_loop().create_timer(SCAN_DELAY_MSEC / 1000.0)
	timer.timeout.connect(_perform_scan, ConnectFlags.CONNECT_ONE_SHOT)


# 内部：实际执行扫描（繁忙时延迟重试，扫描完成后才释放锁）
static func _perform_scan() -> void:
	if not Engine.is_editor_hint():
		_scan_pending = false
		return
	
	var editor_filesystem: EditorFileSystem = EditorInterface.get_resource_filesystem()
	if editor_filesystem == null:
		_scan_pending = false
		return
	
	# 文件系统繁忙（正在扫描/导入）时延迟重试，避免重入崩溃，同时保证最终刷新
	if editor_filesystem.is_scanning() or editor_filesystem.is_importing():
		AIChatLogger.warn("[ToolBox] Filesystem busy, deferring rescan...")
		_schedule_deferred_scan()
		return
	
	AIChatLogger.debug("[ToolBox] Performing deferred filesystem scan...")
	editor_filesystem.scan()
	_scan_pending = false


# 获取Shader编辑器的标签节点
static func _activate_shader_tab(p_node: Node) -> void:
	var parent_tab: Node = p_node.get_parent()
	if parent_tab is TabContainer:
		var tab_container: TabContainer = parent_tab
		for i in tab_container.get_tab_count():
			if tab_container.get_tab_control(i) == p_node:
				tab_container.set_current_tab(i)
				break
