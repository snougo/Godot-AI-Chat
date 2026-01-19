@tool
extends AiTool

func _init() -> void:
	tool_name = "manage_skill"
	tool_description = "Mounts (activates) or Unmounts (deactivates) a skill. Mounting a skill gives you access to new tools and instructions."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["mount", "unmount"],
				"description": "The action to perform."
			},
			"skill_name": {
				"type": "string",
				"description": "The exact name of the skill (case-sensitive) as listed in `list_available_skills`."
			}
		},
		"required": ["action", "skill_name"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var action = _args.get("action", "")
	var skill_name = _args.get("skill_name", "")
	
	if action.is_empty() or skill_name.is_empty():
		return {"success": false, "data": "Error: Both 'action' and 'skill_name' are required."}
	
	# 检查技能是否存在
	if not skill_name in ToolRegistry.get_available_skill_names():
		return {"success": false, "data": "Error: Unknown skill '%s'. Use `list_available_skills` to see valid options." % skill_name}
	
	match action:
		"mount":
			if ToolRegistry.is_skill_active(skill_name):
				return {"success": true, "data": "Skill '%s' is already mounted." % skill_name}
			
			var result = ToolRegistry.mount_skill(skill_name)
			if result:
				# 获取新增的工具列表
				var new_tools = []
				if ToolRegistry.available_skills.has(skill_name):
					var skill = ToolRegistry.available_skills[skill_name]
					if "tools" in skill:
						for tool_path in skill.tools:
							# 尝试加载脚本以获取准确的工具名称
							var script = load(tool_path)
							if script:
								var temp_tool = script.new()
								if "tool_name" in temp_tool:
									new_tools.append(temp_tool.tool_name)
								else:
									new_tools.append(tool_path.get_file()) # 后备方案：使用文件名
				
				var tool_msg = ""
				if not new_tools.is_empty():
					# 格式化为: New Tool has added: "tool_a", "tool_b"
					var quoted_tools = new_tools.map(func(t): return '"%s"' % t)
					tool_msg = "\nNew Tool has added: " + ", ".join(quoted_tools)
				return {"success": true, "data": "Successfully mounted skill: %s.%s" % [skill_name, tool_msg]}
			else:
				return {"success": false, "data": "Failed to mount skill: %s. Check console for details." % skill_name}
		
		"unmount":
			if not ToolRegistry.is_skill_active(skill_name):
				return {"success": true, "data": "Skill '%s' is already inactive." % skill_name}
			
			ToolRegistry.unmount_skill(skill_name)
			return {"success": true, "data": "Successfully unmounted skill: %s." % skill_name}
		
		_:
			return {"success": false, "data": "Invalid action: %s" % action}
