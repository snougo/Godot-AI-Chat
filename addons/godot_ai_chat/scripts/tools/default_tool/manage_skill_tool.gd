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
				return {"success": true, "data": "Successfully mounted skill: %s. You now have access to its capabilities." % skill_name}
			else:
				return {"success": false, "data": "Failed to mount skill: %s. Check console for details." % skill_name}
		
		"unmount":
			if not ToolRegistry.is_skill_active(skill_name):
				return {"success": true, "data": "Skill '%s' is already inactive." % skill_name}
			
			ToolRegistry.unmount_skill(skill_name)
			return {"success": true, "data": "Successfully unmounted skill: %s." % skill_name}
			
		_:
			return {"success": false, "data": "Invalid action: %s" % action}
