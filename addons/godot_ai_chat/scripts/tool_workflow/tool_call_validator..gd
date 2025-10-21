extends RefCounted
class_name ToolCallValidator


# 定义工具调用结构的“白名单”（仅允许这些 tool_name）
static var allowed_tool_names: Array = ["get_context"]

# arguments 中必须包含的字段（如 context_type, path）
static var required_arguments: Dictionary = {
	"context_type": true,
	"path": true
}

# 是否允许 arguments 为空（默认不允许）
static var allow_empty_arguments: bool = false


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 校验一个工具调用是否合法（输入为 Dictionary）
static func validate_tool_call(_tool_call: Dictionary) -> Dictionary:
	var result: Dictionary = {
		"success": false,
		"error_message": "",
		"tool_call": _tool_call
	}
	
	# 1. 基础结构校验
	if not _tool_call.has("tool_name") or not _tool_call.tool_name is String:
		result.error_message = "[ERROR: Missing 'tool_name']"
		return result
	
	if not _tool_call.has("arguments") or typeof(_tool_call.arguments) != TYPE_DICTIONARY:
		result.error_message = "[ERROR: Missing or invalid 'arguments']"
		return result
	
	if not allow_empty_arguments and _tool_call.arguments.is_empty():
		result.error_message = "[ERROR: 'arguments' cannot be empty]"
		return result
	
	# 2. 白名单校验（可选）
	if not allowed_tool_names.is_empty() and not allowed_tool_names.has(_tool_call.tool_name):
		var allowed_str = ""
		for i in range(allowed_tool_names.size()):
			if i > 0:
				allowed_str += ", "
			allowed_str += allowed_tool_names[i]
		result.error_message = "[ERROR: Tool name '%s' is not allowed. Allowed: %s]" % [
			_tool_call.tool_name,
			allowed_str
		]
		return result
	
	# 3. arguments 字段校验
	var args = _tool_call.arguments
	for key in required_arguments:
		if not args.has(key):
			result.error_message = "[ERROR: 'arguments' missing required field '%s']" % key
			return result
	
	# 4. 校验 arguments 字段类型
	if args.has("path") and typeof(args.path) != TYPE_STRING:
		result.error_message = "[ERROR: 'arguments.path' must be a string]"
		return result
	
	if args.has("context_type") and typeof(args.context_type) != TYPE_STRING:
		result.error_message = "[ERROR: 'arguments.context_type' must be a string]"
		return result
	
	# 5. 成功！
	result.success = true
	result.error_message = ""
	return result


# 校验一个原始字符串中的第一个 ```json 工具调用（单次调用场景）
# 要求：必须包含至少一个 ```json ... ``` 代码块
static func validate_raw_tool_call(_raw_call: String) -> Dictionary:
	var fail_result = {
		"success": false,
		"error_message": "",
		"tool_call": {}
	}
	
	var code_block_regex = RegEx.new()
	code_block_regex.compile("(?si)```json\\s*(.*?)\\s*```")
	
	var match = code_block_regex.search(_raw_call)
	if not match:
		fail_result.error_message = "[ERROR: No valid tool call found. Must be wrapped in a ```json ... ``` code block (case-insensitive).]"
		return fail_result
	
	var json_content = match.get_string(1).strip_edges()
	if json_content.is_empty():
		fail_result.error_message = "[ERROR: JSON code block is empty]"
		return fail_result
	
	var json_data = JSON.parse_string(json_content)
	if typeof(json_data) != TYPE_DICTIONARY:
		fail_result.error_message = "[ERROR: Failed to parse JSON inside ```json code block]"
		return fail_result
	
	return validate_tool_call(json_data)


# 从字符串中提取所有 ```json 代码块并解析为 Dictionary 数组（内部使用）
static func _extract_all_json_blocks_as_dictionaries(_raw_call: String) -> Array:
	var results: Array = []
	var code_block_regex = RegEx.new()
	code_block_regex.compile("(?si)```json\\s*(.*?)\\s*```")
	
	var matches = code_block_regex.search_all(_raw_call)
	for match in matches:
		var json_content = match.get_string(1).strip_edges()
		if json_content.is_empty():
			results.append(null)
		else:
			var json_data = JSON.parse_string(json_content)
			results.append(json_data if typeof(json_data) == TYPE_DICTIONARY else null)
	
	return results


# 校验一个字符串中所有的 ```json 工具调用（多调用场景）
static func validate_all_raw_tool_calls_in_string(_raw_call: String) -> Array:
	var extracted = _extract_all_json_blocks_as_dictionaries(_raw_call)
	var results: Array = []
	
	if extracted.is_empty():
		return [{
			"success": false,
			"error_message": "[ERROR: No ```json code blocks found in input]",
			"tool_call": {}
		}]
	
	for item in extracted:
		if item == null:
			results.append({
				"success": false,
				"error_message": "[ERROR: Failed to parse JSON in one of the ```json code blocks]",
				"tool_call": {}
			})
		else:
			results.append(validate_tool_call(item))
	
	return results


# 批量校验多个工具调用字典（Array[Dictionary]）
static func validate_tool_calls(_tool_calls: Array) -> Array:
	var results: Array = []
	for call in _tool_calls:
		results.append(validate_tool_call(call))
	return results


# 批量校验多个原始字符串（每个字符串应包含一个工具调用）
static func validate_raw_tool_calls(_raw_calls: Array) -> Array:
	var results: Array = []
	for raw_call in _raw_calls:
		results.append(validate_raw_tool_call(raw_call))
	return results


# 生成错误提示（用于 UI 显示）
static func generate_error_feedback(_error: Dictionary) -> String:
	if not _error.has("error_message"):
		return "[SYSTEM FEEDBACK] Unknown error."
	
	var msg = _error.error_message
	if _error.has("tool_call") and typeof(_error.tool_call) == TYPE_DICTIONARY:
		msg += "\n\n[Tool Call Content]:\n" + str(_error.tool_call)
	
	return msg
