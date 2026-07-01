@tool
class_name ToolRegistry
extends RefCounted

## 工具注册表
##
## 负责管理 Main-Agent 的核心工具集，并为 Sub-Agent 提供技能列表查询。
## Main-Agent 不挂载技能，只拥有固定核心工具集。

# --- Constants ---

## 核心工具路径 (始终加载给 Main-Agent)
const CORE_TOOLS_PATHS: Array[String] = [
	"res://addons/godot_ai_chat/scripts/tools/file_tool/read_file_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/manage_folder_tool.gd",
	
	"res://addons/godot_ai_chat/scripts/tools/default_tool/get_node_properties_tool.gd",
	
	"res://addons/godot_ai_chat/scripts/tools/todo_list_tool/manage_todo_list_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/todo_list_tool/check_todo_list_tool.gd",
	
	"res://addons/godot_ai_chat/scripts/tools/search_tool/search_web_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/search_tool/search_godot_api_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/search_tool/web_fetch_content_tool.gd",
	
	"res://addons/godot_ai_chat/scripts/tools/memory_tool/add_memory_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/memory_tool/delete_memory_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/memory_tool/search_memories_tool.gd",
	
	"res://addons/godot_ai_chat/scripts/tools/default_tool/create_new_skill_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/other_tool/run_editor_script_tool.gd",
	
	"res://addons/godot_ai_chat/scripts/tools/sub_agent_tool/list_available_skills_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/sub_agent_tool/create_sub_agent_tool.gd"
	]

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


## 获取指定名称的工具实例
static func get_tool(p_tool_name: String) -> Object:
	if main_agent_tools.is_empty():
		load_default_tools()
	return main_agent_tools.get(p_tool_name)


## 获取所有工具的定义（用于 API 调用）
static func get_all_tool_definitions(p_for_gemini: bool = false) -> Array[Dictionary]:
	if main_agent_tools.is_empty():
		load_default_tools()
	
	var definitions: Array[Dictionary] = []
	for tool_instance in main_agent_tools.values():
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
				if resource:
					if "skill_name" in resource:
						available_skills[resource.get("skill_name")] = resource
						AIChatLogger.debug("[ToolRegistry] -> SUCCESS: Loaded ", resource.get("skill_name"))
					else:
						AIChatLogger.error("[ToolRegistry] -> ERROR: Resource has no 'skill_name'")
				else:
					AIChatLogger.error("[ToolRegistry] -> ERROR: load() returned null")
			
			file_name = dir.get_next()
		dir.list_dir_end()


static func _load_core_tools() -> void:
	for path in CORE_TOOLS_PATHS:
		_load_and_register_tool(path)


static func _load_and_register_tool(p_path: String) -> void:
	if not FileAccess.file_exists(p_path):
		AIChatLogger.warn("[ToolRegistry] Tool file not found: %s" % p_path)
		return
	
	var script: Resource = load(p_path)
	
	if script == null:
		AIChatLogger.error("[ToolRegistry] Failed to load script (null): %s" % p_path)
		return
	
	if script is GDScript:
		var tool_instance: Object = script.new()
		if tool_instance.has_method("execute") and tool_instance.has_method("get_parameters_schema"):
			var t_name: String = tool_instance.get("tool_name") if "tool_name" in tool_instance else ""
			if t_name.is_empty() and tool_instance.has_method("get_tool_name"):
				t_name = tool_instance.call("get_tool_name")
			
			if not t_name.is_empty():
				main_agent_tools[t_name] = tool_instance
