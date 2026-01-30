@tool
class_name ToolRegistry
extends RefCounted

## 工具注册表
##
## 负责管理所有可用工具、技能包的加载、挂载与卸载。
## 维护当前激活的工具集，并提供给 LLM Provider 使用。

# --- Enums / Constants ---

## 技能目录
const SKILLS_DIR: String = "res://addons/godot_ai_chat/skills/"

## 核心工具路径 (始终加载)
const CORE_TOOLS_PATHS: Array[String] = [
	"res://addons/godot_ai_chat/scripts/tools/default_tool/list_available_skills_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/manage_skill_tool.gd",
	
	"res://addons/godot_ai_chat/scripts/tools/search_tool/api_documents_search_tool.gd",
	#"res://addons/godot_ai_chat/scripts/tools/search_tool/get_current_date_tool.gd",
	#"res://addons/godot_ai_chat/scripts/tools/search_tool/web_search_tool.gd",
	
	"res://addons/godot_ai_chat/scripts/tools/other_tool/manage_markdown_tool.gd",
	#"res://addons/godot_ai_chat/scripts/tools/other_tool/view_image_tool.gd",
	
	"res://addons/godot_ai_chat/scripts/tools/default_tool/retrieve_context_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/todo_list_tool.gd"
]

# --- Public Vars ---

## 存储当前激活的工具实例 { "tool_name": tool_instance }
static var ai_tools: Dictionary = {}

## 缓存可用技能资源 { "skill_name": skill_resource }
static var available_skills: Dictionary = {}

## 当前已挂载的技能列表 (有序数组，后加载的覆盖先加载的)
static var active_skills_list: Array[String] = []


# --- Public Functions ---

## 初始化默认工具
static func load_default_tools() -> void:
	AIChatLogger.debug("[ToolRegistry] Initializing... Scanning skills and loading Core.")
	_scan_skills()
	# 初始化时，重置挂载列表
	active_skills_list.clear()
	rebuild_tool_set()


## 挂载一个技能
## [param p_skill_name]: 技能名称
## [return]: 是否成功 (如果不存在则失败)
static func mount_skill(p_skill_name: String) -> bool:
	if not available_skills.has(p_skill_name):
		push_error("[ToolRegistry] Cannot mount unknown skill: %s" % p_skill_name)
		return false
	
	if p_skill_name in active_skills_list:
		AIChatLogger.debug("[ToolRegistry] Skill '%s' is already mounted." % p_skill_name)
		return true
	
	# 添加到列表末尾 (优先级最高，覆盖前面的)
	active_skills_list.append(p_skill_name)
	AIChatLogger.debug("[ToolRegistry] Mounting skill: %s" % p_skill_name)
	
	rebuild_tool_set()
	return true


## 卸载一个技能
## [param p_skill_name]: 技能名称
static func unmount_skill(p_skill_name: String) -> void:
	if not p_skill_name in active_skills_list:
		return
	
	active_skills_list.erase(p_skill_name)
	AIChatLogger.debug("[ToolRegistry] Unmounting skill: %s" % p_skill_name)
	
	rebuild_tool_set()


## 检查某个技能是否已激活
## [param p_skill_name]: 技能名称
static func is_skill_active(p_skill_name: String) -> bool:
	return p_skill_name in active_skills_list


## 核心重构逻辑：清空 -> Core -> Skills
static func rebuild_tool_set() -> void:
	# 1. 清空当前工具
	ai_tools.clear()
	
	# 2. 加载核心工具 (Base Layer)
	_load_core_tools()
	
	# 3. 按顺序叠加技能工具 (Overlay Layer)
	# 由于 ai_tools 是字典，后加载的同名工具会直接覆盖旧的
	for skill_name in active_skills_list:
		# 增加健壮性检查: 防止 skill 文件丢失导致 Crash
		if not available_skills.has(skill_name):
			push_warning("[ToolRegistry] Warning: Skill '%s' is in active list but not found in available skills. Skipping." % skill_name)
			continue
		
		var skill: Resource = available_skills[skill_name]
		if "tools" in skill:
			var tools: Array = skill.get("tools")
			for tool_path in tools:
				if tool_path is String and not tool_path.is_empty():
					_load_and_register_tool(tool_path)
	
	AIChatLogger.debug("[ToolRegistry] Tool set rebuilt. Active Skills: %s. Total Tools: %d" % [str(active_skills_list), ai_tools.size()])


## 获取组合后的 System Instructions
static func get_combined_system_instructions() -> String:
	if active_skills_list.is_empty():
		return ""
	
	var combined_prompt: String = ""
	
	for skill_name in active_skills_list:
		# 增加健壮性检查
		if not available_skills.has(skill_name):
			continue
		
		var skill: Resource = available_skills[skill_name]
		var instruction_file: String = skill.get("instruction_file") if "instruction_file" in skill else ""
		
		if not instruction_file.is_empty():
			if FileAccess.file_exists(instruction_file):
				var content: String = FileAccess.get_file_as_string(instruction_file)
				combined_prompt += "\n\n### SKILL MODULE: %s\n%s\n" % [skill_name.to_upper(), content]
	
	return combined_prompt


## 获取指定名称的工具实例
## [param p_tool_name]: 工具名称
static func get_tool(p_tool_name: String) -> Object:
	# 安全检查：防止脚本重载后状态丢失
	if ai_tools.is_empty():
		# 防御性编程：如果未初始化则加载默认
		load_default_tools() 
	return ai_tools.get(p_tool_name)


## 获取所有工具的定义 (用于 API 调用)
## [param p_for_gemini]: 是否针对 Gemini 格式进行转换
static func get_all_tool_definitions(p_for_gemini: bool = false) -> Array[Dictionary]:
	if ai_tools.is_empty():
		load_default_tools()
	
	var definitions: Array[Dictionary] = []
	for tool_instance in ai_tools.values():
		var schema: Dictionary = tool_instance.get_parameters_schema()
		if p_for_gemini:
			schema = convert_schema_to_gemini(schema)
		definitions.append({
			"name": tool_instance.tool_name, 
			"description": tool_instance.tool_description, 
			"parameters": schema
		})
	return definitions


## 获取所有可用技能的名称
static func get_available_skill_names() -> Array:
	# 强制刷新，不使用缓存
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

## 扫描技能目录
static func _scan_skills() -> void:
	available_skills.clear()
	if not DirAccess.dir_exists_absolute(SKILLS_DIR):
		return
	
	var dir: DirAccess = DirAccess.open(SKILLS_DIR)
	if dir:
		dir.list_dir_begin()
		var folder_name: String = dir.get_next()
		while folder_name != "":
			if dir.current_is_dir() and not folder_name.begins_with("."):
				_load_skill_from_folder(SKILLS_DIR.path_join(folder_name))
			folder_name = dir.get_next()
		dir.list_dir_end()


## 从文件夹加载技能资源
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


## 加载核心工具
static func _load_core_tools() -> void:
	for path in CORE_TOOLS_PATHS:
		_load_and_register_tool(path)


## 加载并注册单个工具
static func _load_and_register_tool(p_path: String) -> void:
	if not FileAccess.file_exists(p_path): 
		return
	var script: Resource = load(p_path)
	
	if script and script is GDScript:
		var tool_instance: Object = script.new()
		# Duck Typing Check
		if tool_instance.has_method("execute") and tool_instance.has_method("get_parameters_schema"):
			var t_name: String = tool_instance.get("tool_name") if "tool_name" in tool_instance else ""
			if t_name.is_empty() and tool_instance.has_method("get_tool_name"):
				t_name = tool_instance.call("get_tool_name")
			
			if not t_name.is_empty():
				# 如果 ai_tools[t_name] 已存在，直接覆盖，不报错
				ai_tools[t_name] = tool_instance
