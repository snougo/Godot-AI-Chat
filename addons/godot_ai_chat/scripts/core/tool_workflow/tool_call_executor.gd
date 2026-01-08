@tool
class_name ToolExecutor
extends RefCounted

## 负责执行具体的工具调用，并将结果返回给工作流。

# --- Public Vars ---

## 上下文提供者，用于工具访问编辑器上下文
var context_provider: ContextProvider = ContextProvider.new()

# --- Public Functions ---

## 执行工具调用的入口
## [param _execution_data]: 包含工具名和参数的字典 { "tool_name": String, "arguments": Dictionary }
func execute_tool(_execution_data: Dictionary) -> String:
	var _tool_name: String = _execution_data.get("tool_name", "")
	var _args: Dictionary = _execution_data.get("arguments", {})
	
	if _tool_name.is_empty():
		return "[SYSTEM ERROR] Tool name missing in execution data."
	
	# 从注册中心获取工具
	var _tool_instance: AiTool = ToolRegistry.get_tool(_tool_name)
	if _tool_instance == null:
		return _format_error("Unknown tool: '%s'" % _tool_name)
	
	# 执行
	var _result: Dictionary = _tool_instance.execute(_args, context_provider)
	
	# 格式化结果
	if _result.has("success") and _result.success:
		var _data: Variant = _result.get("data", "")
		# 确保返回字符串
		return str(_data) if not _data is String else _data
	else:
		return _format_error(_result.get("data", "Unknown execution error"))

# --- Private Functions ---

## 格式化错误信息
func _format_error(_msg: String) -> String:
	return "[SYSTEM FEEDBACK - Tool Execution Failed]\n%s" % _msg
