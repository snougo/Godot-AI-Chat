@tool
class_name DispatchToolTask
extends AiTool

## 任务分发工具
## 
## 将工具调用任务分发给本地 AI 子 Agent 执行，
## 避免每次工具调用都发送完整对话上下文到云端模型。

func _init() -> void:
	var tool_name: String = "dispatch_tool_task"
	var tool_description: String = """Dispatch a tool execution task to a local AI sub-agent.
	This tool creates an independent agent session that executes the requested tools locally,
	without sending the full conversation context to the main AI model.
	
	## When to use:
	- When multiple tool calls are needed for a single task
	- When you want to reduce token usage by delegating tool execution
	- When the task is self-contained and doesn't require main agent's context
	
	## Args:
	- task: Clear, detailed instruction for the sub-agent to execute
	- tools: List of tool names the sub-agent is allowed to use (leave empty for auto-detection)
	
	## Returns:
	- success: Whether the task completed successfully
	- data: Summary of what was accomplished or error message
	- tool_calls_count: Number of tool calls made during execution"""


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"task": {
				"type": "string",
				"description": "Detailed task instruction for the sub-agent. Be specific about what tools to use and what to achieve."
			},
			"tools": {
				"type": "array",
				"items": {"type": "string"},
				"description": "List of tool names the sub-agent can use. If empty, will auto-detect from task description. Example: [\"create_script\", \"get_edited_scene\", \"check_node_properties\"]"
			}
		},
		"required": ["task"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var task: String = p_args.get("task", "")
	var tools: Array = p_args.get("tools", [])
	
	if task.is_empty():
		return {"success": false, "data": "Task description is required"}
	
	# 转换工具名称数组
	var tool_names: Array[String] = []
	for t in tools:
		if t is String and not t.is_empty():
			tool_names.append(t)
	
	# 如果没有指定工具，尝试从任务描述推断
	if tool_names.is_empty():
		tool_names = _infer_tools_from_task(task)
		AIChatLogger.debug("[DispatchToolTask] Auto-inferred tools: %s" % str(tool_names))
	
	# 确保至少有一个工具可用
	if tool_names.is_empty():
		return {
			"success": false, 
			"data": "No tools specified and could not infer from task. Please specify the 'tools' parameter."
		}
	
	# 创建子 Agent 编排器
	var orchestrator: SubAgentOrchestrator = SubAgentOrchestrator.new()
	orchestrator.configure(tool_names)
	
	# 添加到场景树以支持 await
	var scene_tree: SceneTree = Engine.get_main_loop()
	if scene_tree:
		scene_tree.root.add_child(orchestrator)
	else:
		return {"success": false, "data": "Failed to access SceneTree"}
	
	# 执行任务并等待完成
	var result: Dictionary = await orchestrator.execute_task(task)
	
	# 清理
	orchestrator.queue_free()
	
	return result


# === Private Functions ===

## 从任务描述推断可能需要的工具
func _infer_tools_from_task(p_task: String) -> Array[String]:
	var inferred: Array[String] = []
	var task_lower: String = p_task.to_lower()
	
	# 场景相关
	if "scene" in task_lower or "node" in task_lower:
		if not "get_edited_scene" in inferred:
			inferred.append("get_edited_scene")
		if not "check_node_properties" in inferred:
			inferred.append("check_node_properties")
		if not "manage_scene_structure" in inferred:
			inferred.append("manage_scene_structure")
	
	# 脚本相关
	if "script" in task_lower or "gdscript" in task_lower or "code" in task_lower:
		if not "get_edited_script" in inferred:
			inferred.append("get_edited_script")
		if not "create_script" in inferred:
			inferred.append("create_script")
	
	# 文件/文件夹/创建相关
	if "folder" in task_lower or "create" in task_lower or "file" in task_lower:
		if not "get_context" in inferred:
			inferred.append("get_context")
	
	# 项目设置相关
	if "project setting" in task_lower or "setting" in task_lower:
		if not "get_project_settings" in inferred:
			inferred.append("get_project_settings")
	
	# 待办事项相关
	if "todo" in task_lower:
		if not "manage_todo_list" in inferred:
			inferred.append("manage_todo_list")
		if not "check_todo_list" in inferred:
			inferred.append("check_todo_list")
	
	# 记忆相关
	if "remember" in task_lower or "memory" in task_lower:
		if not "add_memory" in inferred:
			inferred.append("add_memory")
		if not "search_memories" in inferred:
			inferred.append("search_memories")
	
	# 搜索相关
	if "search" in task_lower or "find" in task_lower or "look up" in task_lower:
		if not "search_api_documents" in inferred:
			inferred.append("search_api_documents")
		if not "search_web" in inferred:
			inferred.append("search_web")
	
	# 日期相关
	if "date" in task_lower or "time" in task_lower or "today" in task_lower:
		if not "get_current_date" in inferred:
			inferred.append("get_current_date")
	
	return inferred
