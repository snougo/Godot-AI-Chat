@tool
extends RefCounted
class_name ToolRegistry

## --- 变量定义 ---

## 存储当前激活的工具实例 { "tool_name": tool_instance }
static var ai_tools: Dictionary = {}

## 缓存可用技能资源 { "skill_name": skill_resource }
static var available_skills: Dictionary = {}

## 当前激活的技能名称 (为空代表仅使用核心工具)
static var active_skill_name: String = ""

## 当前激活的技能指令 (Markdown)
static var active_skill_instructions: String = ""

## 技能目录
const SKILLS_DIR: String = "res://addons/godot_ai_chat/skills/"

## 核心工具路径 (始终加载)
const CORE_TOOLS_PATHS: Array[String] = [
	"res://addons/godot_ai_chat/scripts/tools/default_tool/view_image_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/todo_list_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/notebook_tool.gd"
]


## --- 初始化逻辑 (启动时仅加载核心) ---

static func load_default_tools() -> void:
	print("[ToolRegistry] Initializing... Loading Core Tools only.")
	
	# 1. 扫描技能目录 (仅缓存定义，不加载)
	_scan_skills()
	
	# 2. 强制复位：清空所有工具
	ai_tools.clear()
	active_skill_name = ""
	active_skill_instructions = ""
	
	# 3. 仅加载核心工具
	_load_core_tools()


## --- 技能切换逻辑 (状态机模式：排他性) ---

static func switch_to_skill_by_name(skill_name: String) -> bool:
	# 1. 状态重置：清空当前所有工具 (实现排他性关键)
	ai_tools.clear()
	active_skill_instructions = ""
	
	# 2. 始终重新加载核心工具 (基础状态)
	_load_core_tools()
	
	# 情况 A: 用户选择 "None" 或空字符串 -> 切换回纯核心模式
	if skill_name.is_empty() or skill_name == "None":
		active_skill_name = ""
		print("[ToolRegistry] Switched to Core Tools only.")
		return true
	
	# 情况 B: 尝试切换到指定技能
	if not available_skills.has(skill_name):
		push_error("[ToolRegistry] Skill not found: %s. Reverting to Core Tools." % skill_name)
		active_skill_name = ""
		return false
	
	var skill = available_skills[skill_name]
	
	# 3. 加载该技能专属工具
	if "tools" in skill:
		for tool_path in skill.tools:
			if tool_path and not tool_path.is_empty():
				_load_and_register_tool(tool_path)
	
	# 4. 加载该技能 Markdown 指令
	if "instruction_file" in skill and not skill.instruction_file.is_empty():
		if FileAccess.file_exists(skill.instruction_file):
			active_skill_instructions = FileAccess.get_file_as_string(skill.instruction_file)
		else:
			push_warning("[ToolRegistry] Instruction file missing: %s" % skill.instruction_file)
	
	active_skill_name = skill_name
	print("[ToolRegistry] Active Skill Set: Core + %s" % skill_name)
	return true


## --- 扫描与加载辅助 ---

static func _scan_skills() -> void:
	available_skills.clear()
	if not DirAccess.dir_exists_absolute(SKILLS_DIR): return
	
	var dir = DirAccess.open(SKILLS_DIR)
	if dir:
		dir.list_dir_begin()
		var folder_name = dir.get_next()
		while folder_name != "":
			if dir.current_is_dir() and not folder_name.begins_with("."):
				_load_skill_from_folder(SKILLS_DIR.path_join(folder_name))
			folder_name = dir.get_next()
		dir.list_dir_end()


static func _load_skill_from_folder(folder_path: String) -> void:
	var dir = DirAccess.open(folder_path)
	if dir:
		dir.list_dir_begin()
		var file_name = dir.get_next()
		while file_name != "":
			if not dir.current_is_dir() and (file_name.ends_with(".tres") or file_name.ends_with(".res")):
				var resource = load(folder_path.path_join(file_name))
				if resource and "skill_name" in resource:
					available_skills[resource.skill_name] = resource
			file_name = dir.get_next()
		dir.list_dir_end()


static func _load_core_tools() -> void:
	for path in CORE_TOOLS_PATHS:
		_load_and_register_tool(path)


static func _load_and_register_tool(path: String) -> void:
	if not FileAccess.file_exists(path): return
	var script = load(path)
	if script:
		var tool_instance = script.new()
		# Duck Typing Check
		if tool_instance.has_method("execute") and tool_instance.has_method("get_parameters_schema"):
			var t_name = tool_instance.get("tool_name")
			if not t_name and tool_instance.has_method("get_tool_name"):
				t_name = tool_instance.call("get_tool_name")
			if t_name:
				ai_tools[t_name] = tool_instance


## --- 数据获取 ---

static func get_tool(tool_name: String) -> Object:
	# 安全检查：防止脚本重载后状态丢失
	if ai_tools.is_empty():
		print("[ToolRegistry] Tools empty on access. Reloading defaults...")
		load_default_tools() 
	
	return ai_tools.get(tool_name)


static func get_all_tool_definitions(for_gemini: bool = false) -> Array:
	if ai_tools.is_empty(): load_default_tools()
	
	var definitions = []
	for tool in ai_tools.values():
		var schema = tool.get_parameters_schema()
		if for_gemini: schema = _convert_schema_to_gemini(schema)
		definitions.append({"name": tool.tool_name, "description": tool.tool_description, "parameters": schema})
	return definitions


static func get_available_skill_names() -> Array:
	if available_skills.is_empty(): _scan_skills()
	return available_skills.keys()


static func _convert_schema_to_gemini(schema: Dictionary) -> Dictionary:
	var new_schema = schema.duplicate(true)
	if new_schema.has("type"): new_schema["type"] = new_schema["type"].to_upper()
	if new_schema.has("properties"):
		for key in new_schema["properties"]:
			new_schema["properties"][key] = _convert_schema_to_gemini(new_schema["properties"][key])
	return new_schema
