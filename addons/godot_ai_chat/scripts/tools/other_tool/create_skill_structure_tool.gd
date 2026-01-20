@tool
extends AiTool

const SKILLS_BASE_PATH = "res://addons/godot_ai_chat/skills/"


func _init():
	tool_name = "create_skill_structure"
	tool_description = "Creates a new skill folder structure and generates the SKILL.md file in 'res://addons/godot_ai_chat/skills/'. Use this when the user wants to create a new AI skill."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"skill_folder_name": {
				"type": "string",
				"description": "The folder name for the skill (kebab-case), e.g., 'my-new-skill'. Must be a valid folder name, not a path."
			},
			"skill_md_content": {
				"type": "string",
				"description": "The full content of the SKILL.md file, including frontmatter."
			}
		},
		"required": ["skill_folder_name", "skill_md_content"]
	}


func execute(_args: Dictionary) -> Dictionary:
	var skill_folder_name = _args.get("skill_folder_name", "")
	var skill_md_content = _args.get("skill_md_content", "")
	
	if skill_folder_name.is_empty():
		return {"success": false, "data": "Error: skill_folder_name is required."}
	
	# Basic validation to ensure it's just a folder name
	if skill_folder_name.contains("/") or skill_folder_name.contains("\\") or skill_folder_name.contains(".."):
		return {"success": false, "data": "Error: skill_folder_name must be a simple directory name (no slashes or '..')."}
	
	var target_folder = SKILLS_BASE_PATH.path_join(skill_folder_name)
	
	# Ensure base directory exists
	if not DirAccess.dir_exists_absolute(SKILLS_BASE_PATH):
		return {"success": false, "data": "Error: Base skills directory does not exist at " + SKILLS_BASE_PATH}
	
	# Create main skill folder
	if not DirAccess.dir_exists_absolute(target_folder):
		var err = DirAccess.make_dir_absolute(target_folder)
		if err != OK:
			return {"success": false, "data": "Error creating directory: " + str(err)}
	
	# Create 'reference' subfolder (standard convention)
	var ref_path = target_folder.path_join("reference")
	if not DirAccess.dir_exists_absolute(ref_path):
		DirAccess.make_dir_absolute(ref_path)
	
	# Write SKILL.md
	var file_path = target_folder.path_join("Skill.md")
	var file = FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "data": "Error writing Skill.md: " + str(FileAccess.get_open_error())}
	
	file.store_string(skill_md_content)
	file.close()
	
	return {"success": true, "data": "Successfully created skill structure at " + target_folder}
