@tool
extends RefCounted
class_name ToolExecutor

# ContextProvider 是外部依赖注入的，用于工具访问编辑器上下文
var context_provider: ContextProvider = ContextProvider.new()


# 执行工具调用的入口
# execution_data: { "tool_name": String, "arguments": Dictionary }
func execute_tool(_execution_data: Dictionary) -> String:
	var tool_name = _execution_data.get("tool_name", "")
	var args = _execution_data.get("arguments", {})
	
	if tool_name.is_empty():
		return "[SYSTEM ERROR] Tool name missing in execution data."
	
	# 从注册中心获取工具
	var tool_instance: AiTool = ToolRegistry.get_tool(tool_name)
	if tool_instance == null:
		return _format_error("Unknown tool: '%s'" % tool_name)
	
	# 执行
	# print("[ToolExecutor] Executing: %s with %s" % [tool_name, args])
	var result = tool_instance.execute(args, context_provider)
	
	# 格式化结果
	if result.has("success") and result.success:
		var data = result.get("data", "")
		# 确保返回字符串
		return str(data) if not data is String else data
	else:
		return _format_error(result.get("data", "Unknown execution error"))


func _format_error(_msg: String) -> String:
	return "[SYSTEM FEEDBACK - Tool Execution Failed]\n%s" % _msg
