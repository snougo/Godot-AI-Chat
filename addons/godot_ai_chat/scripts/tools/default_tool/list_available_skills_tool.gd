@tool
extends AiTool

func _init() -> void:
	tool_name = "list_available_skills"
	tool_description = "Lists all available AI skills (capabilities) and their current status (mounted/active or not). Use this to see what you can do or what you can learn."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	# 直接访问 ToolRegistry 静态成员
	var all_skills: Array = ToolRegistry.get_available_skill_names()
	
	if all_skills.is_empty():
		return {"success": true, "data": "No specialized skills found in the registry."}
	
	var output: String = "## Available Skills\n"
	
	for skill_name in all_skills:
		var is_active: bool = ToolRegistry.is_skill_active(skill_name)
		var status_icon: String = "✅" if is_active else "⬜"
		var status_text: String = "**Active (Mounted)**" if is_active else "Inactive (Unmounted)"
		
		# 获取描述信息
		var skill_res = ToolRegistry.available_skills.get(skill_name)
		var desc := ""
		if skill_res and "description" in skill_res:
			desc = skill_res.description
		
		output += "### %s %s\n" % [status_icon, skill_name]
		output += "- **Status**: %s\n" % status_text
		if not desc.is_empty():
			output += "- **Description**: %s\n" % desc
		output += "\n"
	
	output += "---\n"
	output += "> To change status, use the `manage_skill` tool with action='mount' or 'unmount'."
	
	return {"success": true, "data": output}
