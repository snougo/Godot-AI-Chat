@tool
extends AiTool

## Main Agent 用于创建 Sub Agent 的工具


func _init() -> void:
	tool_name = "create_sub_agent"
	tool_description = "Creates a background Sub Agent equipped with a specific Skill to accomplish a sub-task. You will wait for its final report."
	security_level = SecurityLevel.NONE


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"skill_name": {
				"type": "string",
				"description": "The exact name of the Skill to assign to the Sub Agent."
			},
			"task_description": {
				"type": "string",
				"description": "Very detailed instructions on what you want the Sub Agent to do."
			}
		},
		"required": ["skill_name", "task_description"]
	}


func execute(args: Dictionary) -> ToolResult:
	var skill_name = args.get("skill_name", "")
	var task_desc = args.get("task_description", "")
	
	if not ToolRegistry.available_skills.has(skill_name):
		var available = ", ".join(ToolRegistry.available_skills.keys())
		return ToolResult.fail("Skill '%s' not found. Available skills are: [%s]" % [skill_name, available])
	
	var sub_agent_orchestrator: SubAgentOrchestrator = SubAgentOrchestrator.new()
	sub_agent_orchestrator.name = "SubAgentOrchestrator"
	sub_agent_orchestrator.skill_name = skill_name
	sub_agent_orchestrator.task_description = task_desc
	
	var root: Window = Engine.get_main_loop().root
	root.add_child(sub_agent_orchestrator)
	
	var result_summary = await sub_agent_orchestrator.run_task()
	return ToolResult.ok(result_summary)
