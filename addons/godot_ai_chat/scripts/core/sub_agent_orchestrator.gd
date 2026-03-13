@tool
class_name SubAgentOrchestrator
extends Node

const REPORT_TASK_TOOL_SCRIPT = preload("res://addons/godot_ai_chat/scripts/tools/sub_agent_tool/report_task_result_tool.gd")

var skill_name: String = ""
var task_description: String = ""

var _config: SubAgentConfig
var _tools: Dictionary = {}
var _history: ChatMessageHistory


func _exit_tree():
	# RefCounted 对象会在 _tools.clear() 后引用计数归零自动释放
	_tools.clear()
	
	# 清理历史消息
	if is_instance_valid(_history):
		_history = null
	
	# 清理配置
	if is_instance_valid(_config):
		_config = null
	
	AIChatLogger.info("[SubAgent] Removed from scene tree and ready to free.")


func run_task() -> String:
	_config = SubAgentConfig.get_config()
	_history = ChatMessageHistory.new()
	
	AIChatLogger.info("[Sub Agent] Starting task with skill: '%s'" % skill_name)
	
	# 1. 动态隔离加载工具 (不污染主代理)
	_load_isolated_tools()
	
	# 2. 组装独立的系统提示词和用户任务
	var skill_instruction = ""
	var skill_res: Resource = ToolRegistry.available_skills.get(skill_name)
	if skill_res and "instruction_file" in skill_res:
		var path = skill_res.instruction_file
		if FileAccess.file_exists(path):
			skill_instruction = FileAccess.get_file_as_string(path)
	
	# 构建 System 消息（负责：人设、规则、技能能力）
	var final_sys_prompt = _config.base_system_prompt
	if not skill_instruction.is_empty():
		final_sys_prompt += "\n\n=== SKILL INSTRUCTION ===\n" + skill_instruction
	
	_history.add_message(ChatMessage.new(ChatMessage.ROLE_SYSTEM, final_sys_prompt))
	
	# 构建 User 消息（负责：具体的任务触发，激活模型的回复意图）
	var final_user_prompt = "Please execute the following task using your tools:\n\n=== TASK DESCRIPTION ===\n" + task_description
	_history.add_message(ChatMessage.new(ChatMessage.ROLE_USER, final_user_prompt))
	
	# 3. 准备网络提供商
	if _config.model_name.is_empty():
		var err = "Sub Agent 启动失败：模型名称 (model_name) 为空！请在 sub_agent_config.tres 中配置。"
		AIChatLogger.error(err)
		_remove_sub_agent_node_from_root()
		return err
	
	var provider = ProviderFactory.create_provider(_config.api_provider)
	if not provider:
		_remove_sub_agent_node_from_root()
		return "Failed to initialize Sub Agent Provider."
	
	var is_gemini = provider is GeminiProvider
	
	# 4. 后台轮询主循环
	var turns_taken = 0
	var final_report = ""
	var has_reported = false
	
	while turns_taken < _config.max_chat_turns:
		turns_taken += 1
		AIChatLogger.debug("[Sub Agent] --- Turn %d ---" % turns_taken)
		
		# 构建请求
		var tool_defs = _get_tool_definitions(is_gemini)
		var body = provider.build_request_body(_config.model_name, _history.messages, _config.temperature, false, tool_defs)
		var url = provider.get_request_url(_config.api_base_url, _config.model_name, _config.api_key, false)
		var headers = provider.get_request_headers(_config.api_key, false)
		
		# 发起非流式请求 (后台静默)
		var http_request = HTTPRequest.new()
		add_child(http_request)
		http_request.timeout = _config.network_timeout
		
		http_request.request(url, headers, HTTPClient.METHOD_POST, JSON.stringify(body))
		var result = await http_request.request_completed
		http_request.queue_free()
		
		# 检查网络错误/超时
		if result[0] != HTTPRequest.RESULT_SUCCESS or result[1] != 200:
			var err_msg = "Network Error %d / Code %d" % [result[0], result[1]]
			if result[0] == HTTPRequest.RESULT_TIMEOUT:
				err_msg = "Sub Agent Timeout!"
			AIChatLogger.error("[Sub Agent] " + err_msg)
			_remove_sub_agent_node_from_root()
			return err_msg
		
		# 解析响应
		var response = provider.parse_non_stream_response(result[3])
		if response.has("error"):
			var err_msg = "Sub Agent API Error: " + str(response.error)
			if response.has("raw"):
				err_msg += "\nRaw Response: " + str(response.raw)
			AIChatLogger.error(err_msg)
			_remove_sub_agent_node_from_root()
			return "Sub Agent API Error: " + str(response.error)
		
		var content = response.get("content", "")
		var reasoning = response.get("reasoning_content", "")
		var tool_calls = response.get("tool_calls",[])
		
		# 打印思考和输出到控制台
		if not reasoning.is_empty():
			AIChatLogger.info("[Sub Agent Thinking]:\n" + reasoning)
		if not content.is_empty():
			AIChatLogger.info("[Sub Agent Output]:\n" + content)
		
		var assistant_msg = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, content)
		assistant_msg.reasoning_content = reasoning
		assistant_msg.tool_calls = tool_calls
		_history.add_message(assistant_msg)
		
		# 检查是否有工具调用
		if tool_calls.is_empty():
			_remove_sub_agent_node_from_root()
			AIChatLogger.warn("[Sub Agent] Stopped without calling tools.")
			return "Task aborted: Sub Agent stopped reasoning without reporting a result. Last output:\n" + content
		
		# 执行工具
		for tc in tool_calls:
			var t_name = tc.get("function", {}).get("name", "")
			var args_str = tc.get("function", {}).get("arguments", "{}")
			var t_args = JSON.parse_string(JSONRepairHelper.repair_json(args_str))
			if t_args == null: t_args = {}
			
			AIChatLogger.info("[Sub Agent] Executing Tool: " + t_name)
			
			# 拦截并处理汇报工具
			if t_name == "report_task_result":
				final_report = "Status: %s\nSummary: %s" %[t_args.get("status", "unknown"), t_args.get("summary", "")]
				has_reported = true
				break # 退出工具执行循环
			
			# 执行普通工具
			var tool_inst = _tools.get(t_name)
			var t_result = ""
			if tool_inst:
				var res = await tool_inst.execute(t_args)
				t_result = JSON.stringify(res.get("data", res), "\t")
			else:
				t_result = "[ERROR] Tool not found: " + t_name
			
			AIChatLogger.debug("[Sub Agent] Tool Result: " + t_result)
			_history.add_tool_message(t_result, tc.get("id", ""), t_name)
		
		# 如果已经汇报，结束主循环
		if has_reported:
			_remove_sub_agent_node_from_root()
			AIChatLogger.info("[Sub Agent] Task Finished. Returning to Main Agent.")
			return final_report
	
	# 如果超出了最大轮数兜底
	_remove_sub_agent_node_from_root()
	AIChatLogger.warn("[Sub Agent] Exceeded max turns without reporting.")
	return "Task failed: Sub Agent exceeded maximum allowed turns (%d) without calling report_task_result." % _config.max_chat_turns


func _load_isolated_tools() -> void:
	_tools.clear()
	
	# 加载专属汇报工具
	if REPORT_TASK_TOOL_SCRIPT:
		var inst = REPORT_TASK_TOOL_SCRIPT.new()
		_tools[inst.tool_name] = inst
	
	# 加载指定 Skill 的工具
	var skill_res: Resource = ToolRegistry.available_skills.get(skill_name)
	if skill_res and "tools" in skill_res:
		for t_path in skill_res.tools:
			if FileAccess.file_exists(t_path):
				var script = load(t_path)
				if script and script is GDScript:
					var inst = script.new()
					if inst.has_method("execute"):
						_tools[inst.tool_name] = inst


func _get_tool_definitions(is_gemini: bool) -> Array:
	var defs =[]
	for tool_inst in _tools.values():
		var schema = tool_inst.get_parameters_schema()
		if is_gemini:
			schema = ToolRegistry.convert_schema_to_gemini(schema)
			defs.append({
				"name": tool_inst.tool_name, 
				"description": tool_inst.tool_description, 
				"parameters": schema
			})
		else:
			defs.append({
				"type": "function",
				"function": {
					"name": tool_inst.tool_name,
					"description": tool_inst.tool_description,
					"parameters": schema
				}
			})
	
	return defs


func _remove_sub_agent_node_from_root() -> void:
	var sub_agent_orchestrator: SubAgentOrchestrator = null
	var root: Window = Engine.get_main_loop().root # 找到编辑器的根节点
	
	for child in root.get_children(false):
		if "SubAgentOrchestrator" in child.name:
			if child is SubAgentOrchestrator:
				sub_agent_orchestrator = child
				# 释放挂载到编辑器根节点上的子代理节点
				root.remove_child(child)
				queue_free()
