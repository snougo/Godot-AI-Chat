@tool
extends AiTool

# Main Agent 用于创建 Skill Agent 的工具


func _init() -> void:
	tool_name = "create_skill_agent"
	tool_description = "Creates a Skill Agent equipped with a specific Skill to accomplish a sub-task. It runs synchronously: you will block until it reports its final result."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"skill_name": {
				"type": "string",
				"description": "The exact name of the Skill to assign to the Skill Agent (case-sensitive)."
			},
			"task_description": {
				"type": "string",
				"description": "Detailed instructions on what you want the Skill Agent to do."
			}
		},
		"required": ["skill_name", "task_description"]
	}


func execute(args: Dictionary) -> ToolResult:
	var skill_name = args.get("skill_name", "")
	var task_desc = args.get("task_description", "")
	
	if not ToolRegistry.available_skills.has(skill_name):
		# 如果找不到，返回可用列表以引导 AI 纠正
		var available = ", ".join(ToolRegistry.available_skills.keys())
		return ToolResult.fail("Error: Skill '%s' not found. Available skills are: [%s]" % [skill_name, available])
	
	var skill_agent_orchestrator: AIChatSkillAgentOrchestrator = AIChatSkillAgentOrchestrator.new()
	skill_agent_orchestrator.name = "SkillAgentOrchestrator"
	skill_agent_orchestrator.skill_name = skill_name
	skill_agent_orchestrator.task_description = task_desc
	
	var root: Window = Engine.get_main_loop().root # 找到编辑器的根节点
	root.add_child(skill_agent_orchestrator)
	
	# 阻塞等待 Skill Agent 任务循环结束
	var result_summary = await skill_agent_orchestrator.run_task()
	return ToolResult.ok(result_summary)
