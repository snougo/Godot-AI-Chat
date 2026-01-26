@tool
extends AiTool

## 挂载（激活）或卸载（停用）技能。
## 挂载技能可以访问新的工具和指令。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "manage_skill"
	tool_description = "Mounts or Unmounts a skill. Mounting a skill gives you access to new tools and instructions."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
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
				"description": "The exact name of the skill."
			}
		},
		"required": ["action", "skill_name"]
	}


## 执行技能管理操作
## [param p_args]: 包含 action 和 skill_name 的参数字典
## [return]: 包含成功状态和操作结果的字典
func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")
	var skill_name: String = p_args.get("skill_name", "")
	
	if action.is_empty() or skill_name.is_empty():
		return {"success": false, "data": "Tool Error: Both 'action' and 'skill_name' are required."}
	
	if not skill_name in ToolRegistry.get_available_skill_names():
		return {"success": false, "data": "Tool Error: Unknown skill '%s'. Use `list_available_skills` to see valid options." % skill_name}
	
	match action:
		"mount":
			return _mount_skill(skill_name)
		"unmount":
			return _unmount_skill(skill_name)
		_:
			return {"success": false, "data": "Invalid action: %s" % action}


# --- Private Functions ---

## 挂载技能
## [param p_skill_name]: 要挂载的技能名称
## [return]: 操作结果字典
func _mount_skill(p_skill_name: String) -> Dictionary:
	if ToolRegistry.is_skill_active(p_skill_name):
		return {"success": true, "data": "Skill '%s' is already mounted." % p_skill_name}
	
	var result: bool = ToolRegistry.mount_skill(p_skill_name)
	if result:
		var new_tools: Array= _get_skill_tools(p_skill_name)
		var tool_msg := ""
		
		if not new_tools.is_empty():
			var quoted_tools: Array = new_tools.map(func(t): return '"%s"' % t)
			tool_msg = "\nNew Tool has added: " + ", ".join(quoted_tools)
		
		return {"success": true, "data": "Successfully mounted skill: %s.%s" % [p_skill_name, tool_msg]}
	else:
		return {"success": false, "data": "Failed to mount skill: %s. Check console for details." % p_skill_name}


## 卸载技能
## [param p_skill_name]: 要卸载的技能名称
## [return]: 操作结果字典
func _unmount_skill(p_skill_name: String) -> Dictionary:
	if not ToolRegistry.is_skill_active(p_skill_name):
		return {"success": true, "data": "Skill '%s' is already inactive." % p_skill_name}
	
	ToolRegistry.unmount_skill(p_skill_name)
	return {"success": true, "data": "Successfully unmounted skill: %s." % p_skill_name}


## 获取技能包含的工具列表
## [param p_skill_name]: 技能名称
## [return]: 工具名称数组
func _get_skill_tools(p_skill_name: String) -> Array:
	var new_tools := []
	
	if ToolRegistry.available_skills.has(p_skill_name):
		var skill: Object = ToolRegistry.available_skills[p_skill_name]
		if "tools" in skill:
			for tool_path in skill.tools:
				var script: Resource = load(tool_path)
				if script:
					var temp_tool = script.new()
					if "tool_name" in temp_tool:
						new_tools.append(temp_tool.tool_name)
					else:
						new_tools.append(tool_path.get_file())
	
	return new_tools
