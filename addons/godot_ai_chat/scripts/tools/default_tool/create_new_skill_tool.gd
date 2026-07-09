@tool
extends AiTool

## 创建新的技能文件夹结构并生成 Skill.md 文件及对应的 AiSkill 资源文件。

# --- Enums / Constants ---

## 技能基础路径
const SKILLS_BASE_PATH: String = "res://addons/godot_ai_chat/skills/"


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_new_skill"
	tool_description = "Creates a new custom Skill. Skills folder path: `res://addons/godot_ai_chat/skills`"


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"skill_folder_name": {
				"type": "string",
				"description": "The folder name for the skill (kebab_case), Must be a valid folder name, not a path."
			},
			"skill_md_content": {
				"type": "string",
				"description": "The full content of the `SKILL.md` file, including frontmatter."
			}
		},
		"required": ["skill_folder_name", "skill_md_content"]
	}


## 执行创建技能结构操作
## [param p_args]: 包含 skill_folder_name 和 skill_md_content 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> ToolResult:
	var skill_folder_name: String = p_args.get("skill_folder_name", "")
	var skill_md_content: String = p_args.get("skill_md_content", "")
	
	if skill_folder_name.is_empty():
		return ToolResult.fail("Error: skill_folder_name is required.")
	
	var validation_result: ToolResult = _validate_folder_name(skill_folder_name)
	if validation_result.is_fail():
		return validation_result
	
	var target_folder: String = SKILLS_BASE_PATH.path_join(skill_folder_name)
	
	var base_check_result: ToolResult = _check_base_directory()
	if base_check_result.is_fail():
		return base_check_result
	
	var create_result: ToolResult = _create_skill_structure(target_folder, skill_md_content)
	if create_result.is_ok():
		EditorInterface.get_resource_filesystem().scan()
	
	return create_result


# --- Private Functions ---

# 验证文件夹名称
# [param p_folder_name]: 文件夹名称
# [return]: 验证结果字典
func _validate_folder_name(p_folder_name: String) -> ToolResult:
	if p_folder_name.contains("/") or p_folder_name.contains("\\") or p_folder_name.contains(".."):
		return ToolResult.fail("Error: skill_folder_name must be a simple directory name (no slashes or '..').")
	return ToolResult.ok("")


# 检查基础目录是否存在
# [return]: 检查结果字典
func _check_base_directory() -> ToolResult:
	if not DirAccess.dir_exists_absolute(SKILLS_BASE_PATH):
		return ToolResult.fail("Error: Base skills directory does not exist at " + SKILLS_BASE_PATH)
	return ToolResult.ok("")


# 创建技能文件夹结构
# [param p_target_folder]: 目标文件夹路径
# [param p_skill_md_content]: Skill.md 内容
# [return]: 操作结果字典
func _create_skill_structure(p_target_folder: String, p_skill_md_content: String) -> ToolResult:
	var create_folder_result: ToolResult = _create_skill_folder(p_target_folder)
	if create_folder_result.is_fail():
		return create_folder_result
	
	var create_ref_result: ToolResult = _create_reference_folder(p_target_folder)
	if create_ref_result.is_fail():
		return create_ref_result
	
	var write_md_result: ToolResult = _write_skill_md(p_target_folder, p_skill_md_content)
	if write_md_result.is_fail():
		return write_md_result
	
	var create_config_result: ToolResult = _create_sub_agent_config(p_target_folder)
	if create_config_result.is_fail():
		return create_config_result
	
	return _create_skill_resource(p_target_folder, p_skill_md_content)


# 创建技能主文件夹
# [param p_target_folder]: 目标文件夹路径
# [return]: 操作结果字典
func _create_skill_folder(p_target_folder: String) -> ToolResult:
	if not DirAccess.dir_exists_absolute(p_target_folder):
		var err: Error = DirAccess.make_dir_absolute(p_target_folder)
		if err != OK:
			return ToolResult.fail("Error creating directory: " + str(err))
	return ToolResult.ok("")


# 创建 reference 子文件夹
# [param p_target_folder]: 目标文件夹路径
# [return]: 操作结果字典
func _create_reference_folder(p_target_folder: String) -> ToolResult:
	var ref_path: String = p_target_folder.path_join("reference")
	if not DirAccess.dir_exists_absolute(ref_path):
		DirAccess.make_dir_absolute(ref_path)
	return ToolResult.ok("")


# 写入 Skill.md 文件
# [param p_target_folder]: 目标文件夹路径
# [param p_skill_md_content]: Skill.md 内容
# [return]: 操作结果字典
func _write_skill_md(p_target_folder: String, p_skill_md_content: String) -> ToolResult:
	var file_path: String = p_target_folder.path_join("Skill.md")
	var file: FileAccess = FileAccess.open(file_path, FileAccess.WRITE)
	
	if file == null:
		return ToolResult.fail("Error writing Skill.md: " + str(FileAccess.get_open_error()))
	
	file.store_string(p_skill_md_content)
	file.close()
	
	return ToolResult.ok("Successfully created Skill.md at " + file_path)


# 创建 SubAgentConfig 资源文件
# [param p_target_folder]: 技能文件夹路径
# [return]: 操作结果字典
func _create_sub_agent_config(p_target_folder: String) -> ToolResult:
	var config := SubAgentConfig.new()
	# 设置一些合理默认值
	config.api_provider = "OpenAI-ChatCompletions"
	
	var config_path: String = p_target_folder.path_join("sub_agent_config.tres")
	var err: Error = ResourceSaver.save(config, config_path)
	if err != OK:
		return ToolResult.fail("Error: saving sub_agent_config: " + str(err))
	
	return ToolResult.ok("")


# 从 Skill.md 内容中解析技能名称（从 # 标题行提取）
# [param p_md_content]: Skill.md 内容
# [return]: 解析出的技能名称，未找到则返回空字符串
func _parse_skill_name_from_md(p_md_content: String) -> String:
	var lines: PackedStringArray = p_md_content.split("\n")
	for line: String in lines:
		var stripped: String = line.strip_edges()
		if stripped.begins_with("# "):
			return stripped.trim_prefix("# ").strip_edges()
	return ""


# 创建 AiSkill 资源文件（使用引擎 API：ResourceSaver.save）
# [param p_target_folder]: 技能文件夹路径
# [param p_skill_md_content]: Skill.md 内容（用于提取技能名称）
# [return]: 操作结果字典
func _create_skill_resource(p_target_folder: String, p_skill_md_content: String) -> ToolResult:
	var skill_name: String = _parse_skill_name_from_md(p_skill_md_content)
	if skill_name.is_empty():
		return ToolResult.fail("Error: Could not parse skill name from Skill.md title.")
	
	var resource := AiSkill.new()
	resource.skill_name = skill_name
	resource.instruction_file = p_target_folder.path_join("Skill.md")
	resource.tools = []
	
	var config_path: String = p_target_folder.path_join("sub_agent_config.tres")
	if FileAccess.file_exists(config_path):
		resource.sub_agent_config = load(config_path)
	
	var folder_name: String = p_target_folder.get_file()
	var resource_path: String = p_target_folder.path_join(folder_name + ".tres")
	
	var err: Error = ResourceSaver.save(resource, resource_path)
	if err != OK:
		return ToolResult.fail("Error: saving skill resource: " + str(err))
	
	return ToolResult.ok("Successfully created skill at " + p_target_folder + " with resource " + resource_path)
