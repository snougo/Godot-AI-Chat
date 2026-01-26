@tool
class_name ToolExecutor
extends RefCounted

## 工具执行器
##
## 负责执行具体的工具调用，并将结果返回给工作流。

# --- Public Functions ---

## 执行工具调用的入口
## [param p_execution_data]: 包含工具名和参数的字典 { "tool_name": String, "arguments": Dictionary }
func execute_tool(p_execution_data: Dictionary) -> String:
	var tool_name: String = p_execution_data.get("tool_name", "")
	var raw_args: Dictionary = p_execution_data.get("arguments", {})
	
	# 容错处理，确保 args 始终为字典
	var args: Dictionary = {}
	if raw_args is Dictionary:
		args = raw_args
	else:
		args = {}
	
	if tool_name.is_empty():
		return "[SYSTEM ERROR] Tool name missing in execution data."
	
	# 从注册中心获取工具
	var tool_instance: AiTool = ToolRegistry.get_tool(tool_name)
	if tool_instance == null:
		return _format_error("Unknown tool: '%s'" % tool_name)
	
	# 执行
	var result: Dictionary = tool_instance.execute(args)
	
	# 格式化结果
	if result.has("success") and result.success:
		var data: Variant = result.get("data", "")
		return str(data) if not data is String else data
	else:
		return _format_error(result.get("data", "Unknown execution error"))


# --- Private Functions ---

## 格式化错误信息
func _format_error(p_msg: String) -> String:
	return "[SYSTEM FEEDBACK - Tool Execution Failed]\n%s" % p_msg
