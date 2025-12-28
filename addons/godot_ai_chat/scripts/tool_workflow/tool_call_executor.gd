extends RefCounted
class_name ToolExecutor


var context_provider: ContextProvider = ContextProvider.new() # ContextProvider为外部上下文工具调用API接口类


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 从一个已经解析好的工具调用字典执行工具。
# 这是该类的主要入口点。
func tool_call_execute_parsed(_parsed_call: Dictionary) -> String:
	var tool_name = _parsed_call.get("tool_name")
	var arguments = _parsed_call.get("arguments")
	
	# 添加一些健壮性检查
	if not tool_name is String or not arguments is Dictionary:
		var error_msg = "[ERROR: Invalid parsed call structure]"
		push_error(error_msg)
		return error_msg
	
	print("[ToolExecutor] Executing parsed call. Name: '%s', Args: %s" % [tool_name, str(arguments)])
	var context_result: Dictionary = _execute_tool_call(tool_name, arguments)
	
	# 确保总是返回字符串
	if context_result.has("data") and context_result.data is String:
		return context_result.data
	else:
		var error_msg: String = "[ERROR: Tool execution result was not a string]"
		push_error(error_msg)
		return error_msg


#==============================================================================
# ## 内部函数 ##
#==============================================================================


# 根据工具名称和参数，分派并执行具体的工具逻辑。
func _execute_tool_call(_tool_name: String, _arguments: Dictionary) -> Dictionary:
	# 1. 从注册中心获取工具实例
	var tool_instance = ToolRegistry.get_tool(_tool_name)
	
	# 2. 如果工具不存在，返回错误
	if tool_instance == null:
		var feedback = ToolCallUtils.handle_tool_call_error("unknown_tool", {"tool_name": _tool_name})
		return {"success": false, "data": feedback}
	
	# 3. 执行工具逻辑 (注入 context_provider)
	# context_provider 是 ToolExecutor 的成员变量
	return tool_instance.execute(_arguments, context_provider)
