@tool
extends RefCounted
class_name ToolRegistry

## --- 变量定义 ---

## 存储当前激活的工具实例 { "tool_name": tool_instance }
static var ai_tools: Dictionary = {}

## 缓存可用技能资源 { "skill_name": skill_resource }
static var available_skills: Dictionary = {}

## 当前已挂载的技能列表 (有序数组，后加载的覆盖先加载的)
static var active_skills_list: Array[String] = []

## 技能目录
const SKILLS_DIR: String = "res://addons/godot_ai_chat/skills/"

## 核心工具路径 (始终加载)
const CORE_TOOLS_PATHS: Array[String] = [
	"res://addons/godot_ai_chat/scripts/tools/default_tool/retrieve_context_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/api_documents_search_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/web_search_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/get_current_date_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/view_image_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/list_available_skills_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/manage_skill_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/todo_list_tool.gd",
	"res://addons/godot_ai_chat/scripts/tools/default_tool/notebook_tool.gd"
]


## --- 初始化逻辑 ---

static func load_default_tools() -> void:
	print("[ToolRegistry] Initializing... Scanning skills and loading Core.")
	_scan_skills()
	# 初始化时，重置挂载列表
	active_skills_list.clear()
	rebuild_tool_set()


## --- 技能挂载系统 (叠加模式) ---

## 挂载一个技能
## [return]: 是否成功 (如果不存在则失败)
static func mount_skill(skill_name: String) -> bool:
	if not available_skills.has(skill_name):
		push_error("[ToolRegistry] Cannot mount unknown skill: %s" % skill_name)
		return false
	
	if skill_name in active_skills_list:
		print("[ToolRegistry] Skill '%s' is already mounted." % skill_name)
		return true
	
	# 添加到列表末尾 (优先级最高，覆盖前面的)
	active_skills_list.append(skill_name)
	print("[ToolRegistry] Mounting skill: %s" % skill_name)
	
	rebuild_tool_set()
	return true


## 卸载一个技能
static func unmount_skill(skill_name: String) -> void:
	if not skill_name in active_skills_list:
		return
	
	active_skills_list.erase(skill_name)
	print("[ToolRegistry] Unmounting skill: %s" % skill_name)
	
	rebuild_tool_set()


## 检查某个技能是否已激活
static func is_skill_active(skill_name: String) -> bool:
	return skill_name in active_skills_list


## 核心重构逻辑：清空 -> Core -> Skills
static func rebuild_tool_set() -> void:
	# 1. 清空当前工具
	ai_tools.clear()
	
	# 2. 加载核心工具 (Base Layer)
	_load_core_tools()
	
	# 3. 按顺序叠加技能工具 (Overlay Layer)
	# 由于 ai_tools 是字典，后加载的同名工具会直接覆盖旧的
	for skill_name in active_skills_list:
		# [FIX] 增加健壮性检查: 防止 skill 文件丢失导致 Crash
		if not available_skills.has(skill_name):
			push_warning("[ToolRegistry] Warning: Skill '%s' is in active list but not found in available skills. Skipping." % skill_name)
			continue
		
		var skill = available_skills[skill_name]
		if "tools" in skill:
			for tool_path in skill.tools:
				if tool_path and not tool_path.is_empty():
					_load_and_register_tool(tool_path)
	
	print("[ToolRegistry] Tool set rebuilt. Active Skills: %s. Total Tools: %d" % [str(active_skills_list), ai_tools.size()])


## 获取组合后的 System Instructions
static func get_combined_system_instructions() -> String:
	if active_skills_list.is_empty():
		return ""
	
	var combined_prompt: String = ""
	
	for skill_name in active_skills_list:
		# [FIX] 增加健壮性检查
		if not available_skills.has(skill_name):
			continue
		
		var skill = available_skills[skill_name]
		if "instruction_file" in skill and not skill.instruction_file.is_empty():
			if FileAccess.file_exists(skill.instruction_file):
				var content = FileAccess.get_file_as_string(skill.instruction_file)
				combined_prompt += "\n\n### SKILL MODULE: %s\n%s\n" % [skill_name.to_upper(), content]
	
	return combined_prompt


## --- 数据获取 ---

static func get_tool(tool_name: String) -> Object:
	# 安全检查：防止脚本重载后状态丢失
	if ai_tools.is_empty():
		# 防御性编程：如果未初始化则加载默认
		load_default_tools() 
	
	return ai_tools.get(tool_name)


static func get_all_tool_definitions(for_gemini: bool = false) -> Array:
	if ai_tools.is_empty(): load_default_tools()
	
	var definitions = []
	for tool in ai_tools.values():
		var schema = tool.get_parameters_schema()
		if for_gemini: schema = convert_schema_to_gemini(schema)
		definitions.append({"name": tool.tool_name, "description": tool.tool_description, "parameters": schema})
	return definitions


static func get_available_skill_names() -> Array:
	if available_skills.is_empty(): _scan_skills()
	return available_skills.keys()


static func convert_schema_to_gemini(schema: Dictionary) -> Dictionary:
	var new_schema = schema.duplicate(true)
	if new_schema.has("type"): new_schema["type"] = new_schema["type"].to_upper()
	if new_schema.has("properties"):
		for key in new_schema["properties"]:
			new_schema["properties"][key] = convert_schema_to_gemini(new_schema["properties"][key])
	return new_schema


## --- 内部辅助 ---

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
				# 如果 ai_tools[t_name] 已存在，直接覆盖，不报错
				ai_tools[t_name] = tool_instance
