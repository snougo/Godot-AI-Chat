@tool
extends AiTool

## 创建新的技能文件夹结构并生成 SKILL.md 文件。

# --- Enums / Constants ---

## 技能基础路径
const SKILLS_BASE_PATH: String = "res://addons/godot_ai_chat/skills/"


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_skill_structure"
	tool_description = "Creates a new skill folder structure and generates the `SKILL.md` file."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"skill_folder_name": {
				"type": "string",
				"description": "The folder name for the skill (kebab_case), e.g., 'my_new_skill'. Must be a valid folder name, not a path."
			},
			"skill_md_content": {
				"type": "string",
				"description": "The full content of the SKILL.md file, including frontmatter."
			}
		},
		"required": ["skill_folder_name", "skill_md_content"]
	}


## 执行创建技能结构操作
## [param p_args]: 包含 skill_folder_name 和 skill_md_content 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var skill_folder_name: String = p_args.get("skill_folder_name", "")
	var skill_md_content: String = p_args.get("skill_md_content", "")
	
	if skill_folder_name.is_empty():
		return {"success": false, "data": "Error: skill_folder_name is required."}
	
	var validation_result: Dictionary = _validate_folder_name(skill_folder_name)
	if not validation_result.get("success", false):
		return validation_result
	
	var target_folder: String = SKILLS_BASE_PATH.path_join(skill_folder_name)
	
	var base_check_result: Dictionary = _check_base_directory()
	if not base_check_result.get("success", false):
		return base_check_result
	
	var create_result: Dictionary = _create_skill_structure(target_folder, skill_md_content)
	return create_result


# --- Private Functions ---

## 验证文件夹名称
## [param p_folder_name]: 文件夹名称
## [return]: 验证结果字典
func _validate_folder_name(p_folder_name: String) -> Dictionary:
	if p_folder_name.contains("/") or p_folder_name.contains("\\") or p_folder_name.contains(".."):
		return {"success": false, "data": "Error: skill_folder_name must be a simple directory name (no slashes or '..')."}
	return {"success": true}


## 检查基础目录是否存在
## [return]: 检查结果字典
func _check_base_directory() -> Dictionary:
	if not DirAccess.dir_exists_absolute(SKILLS_BASE_PATH):
		return {"success": false, "data": "Error: Base skills directory does not exist at " + SKILLS_BASE_PATH}
	return {"success": true}


## 创建技能文件夹结构
## [param p_target_folder]: 目标文件夹路径
## [param p_skill_md_content]: Skill.md 内容
## [return]: 操作结果字典
func _create_skill_structure(p_target_folder: String, p_skill_md_content: String) -> Dictionary:
	var create_folder_result: Dictionary = _create_skill_folder(p_target_folder)
	if not create_folder_result.get("success", false):
		return create_folder_result
	
	var create_ref_result: Dictionary = _create_reference_folder(p_target_folder)
	if not create_ref_result.get("success", false):
		return create_ref_result
	
	return _write_skill_md(p_target_folder, p_skill_md_content)


## 创建技能主文件夹
## [param p_target_folder]: 目标文件夹路径
## [return]: 操作结果字典
func _create_skill_folder(p_target_folder: String) -> Dictionary:
	if not DirAccess.dir_exists_absolute(p_target_folder):
		var err: Error = DirAccess.make_dir_absolute(p_target_folder)
		if err != OK:
			return {"success": false, "data": "Error creating directory: " + str(err)}
	return {"success": true}


## 创建 reference 子文件夹
## [param p_target_folder]: 目标文件夹路径
## [return]: 操作结果字典
func _create_reference_folder(p_target_folder: String) -> Dictionary:
	var ref_path: String = p_target_folder.path_join("reference")
	if not DirAccess.dir_exists_absolute(ref_path):
		DirAccess.make_dir_absolute(ref_path)
	return {"success": true}


## 写入 Skill.md 文件
## [param p_target_folder]: 目标文件夹路径
## [param p_skill_md_content]: Skill.md 内容
## [return]: 操作结果字典
func _write_skill_md(p_target_folder: String, p_skill_md_content: String) -> Dictionary:
	var file_path: String = p_target_folder.path_join("Skill.md")
	var file: FileAccess = FileAccess.open(file_path, FileAccess.WRITE)
	
	if file == null:
		return {"success": false, "data": "Error writing Skill.md: " + str(FileAccess.get_open_error())}
	
	file.store_string(p_skill_md_content)
	file.close()
	
	return {"success": true, "data": "Successfully created skill structure at " + p_target_folder}
