@tool
class_name SubAgentOrchestrator
extends Node

## 子 Agent 编排器
## 
## 独立的会话循环，处理工具调用直到任务完成。
## 工具列表由外部指定，实现与主 Agent 的工具隔离。

# === Signals ===

signal task_completed(result: Dictionary)

# === Private Vars ===

var _history: ChatMessageHistory = null
var _network_manager: NetworkManager = null
var _available_tools: Dictionary = {}      # {tool_name: tool_instance}
var _tool_definitions: Array = []          # 用于 API 请求的工具定义
var _turn_count: int = 0
var _is_cancelled: bool = false


# === Public Functions ===

## 配置并初始化
## [param p_tool_names]: 可用的工具名称列表
func configure(p_tool_names: Array[String]) -> void:
	# 创建独立的历史记录
	_history = ChatMessageHistory.new()
	
	# 创建独立的 NetworkManager
	_network_manager = NetworkManager.new()
	add_child(_network_manager)
	
	# 设置网络超时
	_network_manager._http_request_node.timeout = SubAgentConfig.NETWORK_TIMEOUT
	
	# 应用硬编码配置
	_apply_config()
	
	# 从 ToolRegistry 复制指定工具（浅隔离）
	_setup_available_tools(p_tool_names)


## 执行工具任务
## [param p_task_instruction]: 任务指令
## [return]: {success: bool, data: String, tool_calls_count: int}
func execute_task(p_task_instruction: String) -> Dictionary:
	_turn_count = 0
	_is_cancelled = false
	
	# 注入 System Prompt
	_history.add_message(ChatMessage.new(
		ChatMessage.ROLE_SYSTEM,
		SubAgentConfig.SYSTEM_PROMPT
	))
	
	# 添加任务指令
	_history.add_user_message(p_task_instruction)
	
	AIChatLogger.debug("[SubAgent] Starting task: %s..." % p_task_instruction.left(50))
	
	# 执行会话循环
	var tool_calls_total: int = 0
	
	while _turn_count < SubAgentConfig.MAX_TURNS and not _is_cancelled:
		var result: Dictionary = await _run_single_turn()
		
		if _is_cancelled:
			return {
				"success": false, 
				"data": "Task cancelled", 
				"tool_calls_count": tool_calls_total
			}
		
		if result.completed:
			AIChatLogger.debug("[SubAgent] Task completed in %d turns, %d tool calls" % [_turn_count + 1, tool_calls_total])
			return {
				"success": true,
				"data": result.summary,
				"tool_calls_count": tool_calls_total
			}
		
		tool_calls_total += result.tool_calls_count
		_turn_count += 1
	
	# 超过最大轮数
	AIChatLogger.warn("[SubAgent] Max turns exceeded")
	return {
		"success": false,
		"data": "Max turns (%d) exceeded. Task may be incomplete." % SubAgentConfig.MAX_TURNS,
		"tool_calls_count": tool_calls_total
	}


## 取消当前任务
func cancel() -> void:
	_is_cancelled = true
	if _network_manager:
		_network_manager.cancel_stream()


# === Private Functions ===

func _apply_config() -> void:
	_network_manager.api_base_url = SubAgentConfig.LOCAL_BASE_URL
	_network_manager.api_key = SubAgentConfig.LOCAL_API_KEY
	_network_manager.current_model_name = SubAgentConfig.LOCAL_MODEL_NAME
	_network_manager.temperature = SubAgentConfig.TEMPERATURE
	_network_manager.current_provider = OpenAICompatibleProvider.new()


func _setup_available_tools(p_tool_names: Array[String]) -> void:
	_available_tools.clear()
	_tool_definitions.clear()
	
	for tool_name: String in p_tool_names:
		var tool_instance: Object = ToolRegistry.get_tool(tool_name)
		if tool_instance:
			_available_tools[tool_name] = tool_instance
			
			# 构建工具定义
			var schema: Dictionary = tool_instance.get_parameters_schema()
			_tool_definitions.append({
				"type": "function",
				"function": {
					"name": tool_instance.tool_name,
					"description": tool_instance.tool_description,
					"parameters": schema
				}
			})
			
			AIChatLogger.debug("[SubAgent] Tool loaded: %s" % tool_name)
		else:
			AIChatLogger.warn("[SubAgent] Tool not found: %s" % tool_name)
	
	AIChatLogger.debug("[SubAgent] Available tools: %d" % _available_tools.size())
	
	# 应用自定义工具定义到 NetworkManager
	if _network_manager:
		_network_manager.custom_tools = _tool_definitions


func _run_single_turn() -> Dictionary:
	var context: Array[ChatMessage] = _build_context()
	var response: Dictionary = await _network_manager.request_chat_async(context)
	
	if not response.success:
		return {
			"completed": true, 
			"summary": "Network error: %s" % response.error, 
			"tool_calls_count": 0
		}
	
	var last_msg: ChatMessage = _history.get_last_message()
	if not last_msg or last_msg.role != ChatMessage.ROLE_ASSISTANT:
		return {
			"completed": true, 
			"summary": "Invalid response state", 
			"tool_calls_count": 0
		}
	
	# 没有工具调用 = 任务完成
	if last_msg.tool_calls.is_empty():
		return {
			"completed": true, 
			"summary": last_msg.content, 
			"tool_calls_count": 0
		}
	
	# 过滤幻觉工具调用（与主 Agent 保持一致）
	var is_gemini: bool = (_network_manager.current_provider is GeminiProvider)
	if not is_gemini and "<think>" in last_msg.content:
		last_msg.tool_calls = ToolBox.filter_hallucinated_tool_calls(last_msg.content, last_msg.tool_calls)
		if last_msg.tool_calls.is_empty():
			return {
				"completed": true, 
				"summary": "Filtered hallucinated tool calls. Task may be complete.", 
				"tool_calls_count": 0
			}
	
	# 执行工具调用
	var tool_calls_count: int = 0
	for call: Dictionary in last_msg.tool_calls:
		if _is_cancelled:
			break
		await _execute_tool_call(call)
		tool_calls_count += 1
	
	return {"completed": false, "tool_calls_count": tool_calls_count}


func _execute_tool_call(p_call: Dictionary) -> void:
	var tool_name: String = p_call.get("function", {}).get("name", "")
	var raw_args: String = p_call.get("function", {}).get("arguments", "{}")
	var call_id: String = p_call.get("id", "")
	
	if call_id.is_empty():
		call_id = "subcall_%d" % Time.get_ticks_msec()
	
	# 清洗模型画蛇添足的 XML 标签
	tool_name = tool_name.replace("<tool_call>", "").replace("</tool_call>", "").replace("tool_call", "").strip_edges()
	
	# 验证工具名称有效性，跳过幻觉/代码片段
	if not _is_valid_tool_name(tool_name):
		AIChatLogger.warn("[AgentOrchestrator] Invalid tool name detected, skipping: \"%s\"" % tool_name)
	
	# 解析参数
	var clean_args_str: String = JSONRepairHelper.repair_json(raw_args)
	var args: Variant = JSON.parse_string(clean_args_str)
	if args == null:
		args = {}
	
	var result_str: String = ""
	
	# 从可用工具字典中获取（隔离）
	var tool_instance: Object = _available_tools.get(tool_name)
	
	if tool_instance:
		var result: Dictionary = await tool_instance.execute(args)
		var data: Variant = result.get("data", "")
		
		if data is Dictionary or data is Array:
			result_str = JSON.stringify(data, "\t")
		else:
			result_str = str(data)
		
		AIChatLogger.debug("[SubAgent] Tool '%s' executed" % tool_name)
	else:
		result_str = "[ERROR] Tool '%s' is not available in this context." % tool_name
		AIChatLogger.warn("[SubAgent] Tool '%s' not available" % tool_name)
	
	# 添加工具结果到历史
	_history.add_tool_message(result_str, call_id, tool_name)


func _build_context() -> Array[ChatMessage]:
	# 构建上下文，使用配置的最大轮数
	return _history.get_truncated_messages(SubAgentConfig.MAX_TURNS)


# 验证工具名称是否有效
func _is_valid_tool_name(p_name: String) -> bool:
	if p_name.is_empty():
		return false
	
	if p_name.length() > 64:
		return false
	
	# 检查是否包含换行符或特殊字符（明显是代码片段）
	if "\n" in p_name or "(" in p_name or ")" in p_name:
		return false
	
	# 必须符合函数命名规范
	var regex := RegEx.create_from_string("^[a-zA-Z][a-zA-Z0-9_-]*$")
	return regex.search(p_name) != null
