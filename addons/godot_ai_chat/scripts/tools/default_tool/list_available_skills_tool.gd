@tool
extends AiTool

## 列出所有可用的 AI 技能及其当前状态（已挂载/激活或未激活）。
## 用于查看当前可用的功能或可以学习的新技能。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "list_available_skills"
	tool_description = "Lists all available AI skills and their current status."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


## 执行工具逻辑，列出所有可用技能
## [param p_args]: 参数字典（此工具不需要参数）
## [return]: 包含成功状态和技能列表的字典
func execute(p_args: Dictionary) -> Dictionary:
	var all_skills: Array = ToolRegistry.get_available_skill_names()
	
	if all_skills.is_empty():
		return {"success": true, "data": "No specialized skills found in the registry."}
	
	var output: String = "## Available Skills\n"
	
	for skill_name in all_skills:
		var is_active: bool = ToolRegistry.is_skill_active(skill_name)
		var status_icon: String = "✅" if is_active else "⬜"
		var status_text: String = "**Active (Mounted)**" if is_active else "Inactive (Unmounted)"
		
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
