class_name ToolRegistry
extends RefCounted

## 工具注册表
##
## 负责管理 Main-Agent 的核心工具集，并为 Sub-Agent 提供技能列表查询。
## Main-Agent 不挂载技能，只拥有固定核心工具集。


# --- Public Vars ---

## 存储 Main-Agent 的核心工具实例 { "tool_name": tool_instance }
static var main_agent_tools: Dictionary = {}

## 缓存可用技能资源 { "skill_name": skill_resource }
static var available_skills: Dictionary = {}


# --- Public Functions ---

## 初始化：扫描技能 + 加载核心工具
static func load_default_tools() -> void:
	AIChatLogger.debug("[ToolRegistry] Initializing... Scanning skills and loading core tools.")
	_scan_skills()
	main_agent_tools.clear()
	_load_core_tools()
	AIChatLogger.debug("[ToolRegistry] Core tools loaded. Total Tools: %d" % main_agent_tools.size())


## 仅重新加载核心工具集（不重扫技能）
## 用于工具配置变更后的即时刷新，避免每次聊天循环都产生 skills 目录扫描 IO
static func reload_core_tools_only() -> void:
	main_agent_tools.clear()
	_load_core_tools()


## 获取指定名称的工具实例
static func get_tool(p_tool_name: String) -> Object:
	if main_agent_tools.is_empty():
		load_default_tools()
	return main_agent_tools.get(p_tool_name)


## 构建 OpenAI / Gemini 两种格式的工具定义数组
## [param p_tools]: 工具实例字典 { "tool_name": tool_instance }
## [param p_for_gemini]: 是否生成 Gemini 兼容格式（顶展 schema、大写 type）
## [return]: 工具定义数组
static func build_tool_definitions(p_tools: Dictionary, p_for_gemini: bool) -> Array[Dictionary]:
	var definitions: Array[Dictionary] = []
	for tool_instance in p_tools.values():
		var schema: Dictionary = tool_instance.get_parameters_schema()
		if p_for_gemini:
			schema = convert_schema_to_gemini(schema)
			definitions.append({
				"name": tool_instance.tool_name,
				"description": tool_instance.tool_description,
				"parameters": schema
			})
		else:
			definitions.append({
				"type": "function",
				"function": {
					"name": tool_instance.tool_name,
					"description": tool_instance.tool_description,
					"parameters": schema
				}
			})
	return definitions


## 获取所有工具的定义（用于 API 调用）
static func get_all_tool_definitions(p_for_gemini: bool = false) -> Array[Dictionary]:
	if main_agent_tools.is_empty():
		load_default_tools()
	return build_tool_definitions(main_agent_tools, p_for_gemini)


## 获取所有可用技能的名称
static func get_available_skill_names() -> Array:
	_scan_skills()
	return available_skills.keys()


## 将 Schema 转换为 Gemini 兼容格式
static func convert_schema_to_gemini(p_schema: Dictionary) -> Dictionary:
	var new_schema: Dictionary = p_schema.duplicate(true)
	if new_schema.has("type") and new_schema["type"] is String:
		new_schema["type"] = new_schema["type"].to_upper()
	if new_schema.has("properties") and new_schema["properties"] is Dictionary:
		for key in new_schema["properties"]:
			new_schema["properties"][key] = convert_schema_to_gemini(new_schema["properties"][key])
	return new_schema


# --- Private Functions ---

static func _scan_skills() -> void:
	available_skills.clear()
	if not DirAccess.dir_exists_absolute(PluginPaths.SKILLS_DIR):
		return
	
	var dir: DirAccess = DirAccess.open(PluginPaths.SKILLS_DIR)
	if dir:
		dir.list_dir_begin()
		var folder_name: String = dir.get_next()
		while folder_name != "":
			if dir.current_is_dir() and not folder_name.begins_with("."):
				_load_skill_from_folder(PluginPaths.SKILLS_DIR.path_join(folder_name))
			folder_name = dir.get_next()
		dir.list_dir_end()


static func _load_skill_from_folder(p_folder_path: String) -> void:
	var dir: DirAccess = DirAccess.open(p_folder_path)
	if dir:
		dir.list_dir_begin()
		var file_name: String = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and (file_name.ends_with(".tres") or file_name.ends_with(".res")):
				var resource: Resource = load(p_folder_path.path_join(file_name))
				if resource is AiSkill:
					if not resource.skill_name.is_empty():
						available_skills[resource.skill_name] = resource
						AIChatLogger.debug("[ToolRegistry] -> SUCCESS: Loaded ", resource.skill_name)
					else:
						AIChatLogger.warn("[ToolRegistry] -> AiSkill resource has empty skill_name: ", file_name)
				# 非 AiSkill 的资源（如 SubAgentConfig）静默跳过，不再报错
			
			file_name = dir.get_next()
		dir.list_dir_end()


static func _load_core_tools() -> void:
	var config: MainAgentToolConfig = MainAgentToolConfig.get_config()
	if config == null:
		AIChatLogger.error("[ToolRegistry] Failed to load MainAgentToolConfig: %s" % PluginPaths.MAIN_AGENT_TOOL_CONFIG_PATH)
		return
	if config.tool_scripts.is_empty():
		AIChatLogger.warn("[ToolRegistry] MainAgentToolConfig '%s' has no tool_scripts, no tools loaded." % config.config_name)
		return
	for path in config.tool_scripts:
		_load_and_register_tool(path)


static func _load_and_register_tool(p_path: String) -> void:
	var tool_path: String = _resolve_tool_path(p_path)
	if tool_path.is_empty():
		AIChatLogger.warn("[ToolRegistry] Cannot resolve tool path: %s" % p_path)
		return
	if not FileAccess.file_exists(tool_path):
		AIChatLogger.warn("[ToolRegistry] Tool file not found: %s" % tool_path)
		return
	
	var script: Resource = load(tool_path)
	
	if script == null:
		AIChatLogger.error("[ToolRegistry] Failed to load script (null): %s" % tool_path)
		return
	
	if script is GDScript:
		var tool_instance: Object = script.new()
		if tool_instance.has_method("execute") and tool_instance.has_method("get_parameters_schema"):
			var t_name: String = tool_instance.tool_name
			if not t_name.is_empty():
				main_agent_tools[t_name] = tool_instance


# 将工具引用解析为实际脚本路径（兼容 res:// 路径与 uid:// 引用两种存储形式）
static func _resolve_tool_path(p_path: String) -> String:
	if p_path.begins_with("uid://"):
		var uid: int = ResourceUID.text_to_id(p_path)
		return ResourceUID.get_id_path(uid)
	return p_path
