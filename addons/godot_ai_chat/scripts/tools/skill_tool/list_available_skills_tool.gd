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
		#var status_text: String = "**Active (Mounted)**" if is_active else "Inactive (Unmounted)"
		var status_text: String = "**Active (Used by Sub-Agent)**" if is_active else "Inactive (Not Used by Sub-Agent)"
		
		var skill_res = ToolRegistry.available_skills.get(skill_name)
		var desc := ""
		if skill_res and "description" in skill_res:
			desc = skill_res.description
		
		output += "### %s %s\n" % [status_icon, skill_name]
		output += "- **Status**: %s\n" % status_text
		if not desc.is_empty():
			output += "- **Description**: %s\n" % desc
		
		# 添加工具列表
		var tool_names: Array[String] = []
		if skill_res and "tools" in skill_res:
			var tools: Array = skill_res.get("tools")
			for tool_path in tools:
				if tool_path is String and not tool_path.is_empty():
					var tool_name_str := _get_tool_name_from_path(tool_path)
					if not tool_name_str.is_empty():
						tool_names.append(tool_name_str)
		
		if tool_names.is_empty():
			output += "- **Tools**: None\n"
		else:
			output += "- **Tools**: %s\n" % ", ".join(tool_names)
		
		output += "\n"
	
	output += "---\n"
	#output += "> To change status, use the `manage_skill` tool with action='mount' or 'unmount'."
	
	return {"success": true, "data": output}


# --- Private Functions ---

# 从工具脚本路径获取工具名称
# [param p_tool_path]: 工具脚本文件路径
# [return]: 工具名称（如果获取失败则返回空字符串）
func _get_tool_name_from_path(p_tool_path: String) -> String:
	if not FileAccess.file_exists(p_tool_path):
		return ""
	
	var script: Resource = load(p_tool_path)
	if script == null or not script is GDScript:
		return ""
	
	var tool_instance: Object = script.new()
	if tool_instance == null:
		return ""
	
	var t_name: String = ""
	if "tool_name" in tool_instance:
		t_name = tool_instance.get("tool_name")
	elif tool_instance.has_method("get_tool_name"):
		t_name = tool_instance.call("get_tool_name")
	
	return t_name
