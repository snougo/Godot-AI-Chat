extends RefCounted
class_name ToolCallUtils


# 用于匹配 ```json {...} ``` 或 ``` {...} ``` 格式的 Markdown 代码块。
# (?s) 标志允许 . 匹配换行符，以处理多行JSON。
# (?:json)? 是一个非捕获组，表示 "json" 是可选的。
#const JSON_MARKDOWN_REGEX = "(?s)```(?:json)?\\s*(\\{.*?\\})\\s*```"


#==============================================================================
# ## 静态函数 ##
#==============================================================================

# 一个“安静”的检查器，只判断文本是否可能包含工具调用，不产生警告。
static func _text_content_likely_contains_tool_call(_raw_text: String) -> bool:
	# 策略 1: 检查 gpt-oss 格式
	var gpt_oss_regex = RegEx.new()
	gpt_oss_regex.compile("(?s)<\\|channel\\|>\\s*commentary\\s+to=([a-zA-Z0-9_.]+)")
	if gpt_oss_regex.search(_raw_text):
		return true
	
	# 策略 2: 检查标准的 ```json 格式
	var json_block_regex = RegEx.new()
	json_block_regex.compile("(?si)```json\\s*\\{") # 只需检查块的开头即可，更高效
	if json_block_regex.search(_raw_text):
		return true
		
	return false


# 判断一个AI响应是否包含任何形式的工具调用。
static func has_tool_call_response(_response_data: Dictionary) -> bool:
	# 情况1: 检查是否存在结构化的工具调用数组。
	var has_structured_tool_calls: bool = _response_data.has("tool_calls") and _response_data.tool_calls is Array and not _response_data.tool_calls.is_empty()
	if has_structured_tool_calls:
		return true
	
	# 情况2: 检查文本内容中是否包含任何已知格式的工具调用标签。
	var content = _response_data.get("content", "")
	if not content.is_empty():
		# 调用新的“安静”检查函数，而不是会产生警告的 extract_all_tool_calls
		if _text_content_likely_contains_tool_call(content):
			return true
	
	return false


# 将任何格式的工具调用响应，统一转换为标准的结构化格式。
static func normalize_response_for_tool_workflow(_response_data: Dictionary) -> Dictionary:
	var response_data: Dictionary = _response_data.duplicate(true)
	
	# 如果已经是标准格式，则直接返回。
	if response_data.has("tool_calls") and response_data.tool_calls is Array and not response_data.tool_calls.is_empty():
		return response_data
	
	var content = response_data.get("content", "")
	if content.is_empty():
		return response_data
	
	# 从文本中提取工具调用。
	var parsed_calls: Array = extract_all_tool_calls(content)
	if parsed_calls.is_empty():
		return response_data
	
	# 将提取出的文本格式工具调用转换为结构化数组。
	var structured_calls: Array = []
	for i in range(parsed_calls.size()):
		var tool_call = parsed_calls[i]
		structured_calls.append({
			"id": "call_text_%d" % i,
			"type": "function",
			"function": {
				"name": tool_call.tool_name, 
				"arguments": JSON.stringify(tool_call)
			}
		})
	
	response_data["tool_calls"] = structured_calls
	return response_data


# 从原始文本中提取所有有效的工具调用。
static func extract_all_tool_calls(_raw_text: String) -> Array:
	var all_calls: Array = []
	
	# 策略 1: 优先尝试解析 gpt-oss 原生格式 (来自 LM Studio)。
	var gpt_oss_regex = RegEx.new()
	gpt_oss_regex.compile("(?s)<\\|channel\\|>\\s*commentary\\s+to=([a-zA-Z0-9_.]+)\\s*<\\|constrain\\|>\\s*json\\s*<\\|message\\|>\\s*(\\{.*\\})")
	var gpt_oss_match = gpt_oss_regex.search(_raw_text)
	
	if gpt_oss_match:
		var json_string: String = gpt_oss_match.get_string(2).strip_edges()
		var json_data = JSON.parse_string(json_string)
		
		if typeof(json_data) == TYPE_DICTIONARY and json_data.has("tool_name") and json_data.has("arguments"):
			var args = json_data.arguments
			if typeof(args) == TYPE_DICTIONARY and args.has("context_type") and args.has("path"):
				all_calls.append(json_data)
				return all_calls
			else:
				push_warning("[ToolCallUtils] GPT-OSS tool call JSON arguments missing 'context_type' or 'path': %s" % json_string)
		else:
			push_warning("[ToolCallUtils] GPT-OSS tool call JSON parsing failed or missing keys: %s" % json_string)
		
		return all_calls
	
	# 策略 2: 如果未找到 gpt-oss 格式，回退到标准的 ```json 格式（使用 ToolCallValidator）。
	#var command_regex: RegEx = RegEx.new()
	#command_regex.compile(JSON_MARKDOWN_REGEX)
	#var matches: Array[RegExMatch] = command_regex.search_all(_raw_text)
	#
	#for match in matches:
		#var json_string: String = match.get_string(1)
		#var json_data = JSON.parse_string(json_string)
		#
		#if typeof(json_data) == TYPE_DICTIONARY and json_data.has("tool_name") and json_data.has("arguments"):
			#var args = json_data.arguments
			#if typeof(args) == TYPE_DICTIONARY and args.has("context_type") and args.has("path"):
				#all_calls.append(json_data)
	
	var validation_results: Array = ToolCallValidator.validate_all_raw_tool_calls_in_string(_raw_text)
	
	for result in validation_results:
		if result.success:
			all_calls.append(result.tool_call)
		else:
			# 只有在明确需要提取时，如果提取失败才打印警告，这是合理的。
			# 但我们只在确定有工具调用时才调用这个函数，所以需要判断一下。
			# 如果结果数组为空，且原始文本不为空，说明尝试解析但失败了。
			if not _raw_text.strip_edges().is_empty():
				push_warning("[ToolCallUtils] Invalid standard tool call: %s" % result.error_message)
	
	return all_calls


# 验证并解析单个工具调用字符串。
static func validate_and_parse_tool_call(_raw_call: String) -> Dictionary:
	# 剥离 <think> 标签
	var think_regex: RegEx = RegEx.new()
	think_regex.compile("(?s)<think>.*?</think>\\s*")
	var command_only: String = think_regex.sub(_raw_call, "", true).strip_edges()
	
	# 语法校验
	#var command_regex: RegEx = RegEx.new()
	#command_regex.compile(JSON_MARKDOWN_REGEX)
	#var match: RegExMatch = command_regex.search(command_only)
	#if not match:
		#return {"success": false, "error_type": "syntax_error", "invalid_part": command_only}
	
	# 尝试解析JSON并验证其内部结构
	#var json_string: String = match.get_string(1)
	#var json_data = JSON.parse_string(json_string)
	#if typeof(json_data) != TYPE_DICTIONARY or not json_data.has("tool_name") or not json_data.has("arguments"):
		#return {"success": false, "error_type": "invalid_json", "invalid_part": command_only}
	
	#var args = json_data.arguments
	#if typeof(args) != TYPE_DICTIONARY or not args.has("context_type") or not args.has("path"):
		#return {"success": false, "error_type": "invalid_json_arguments", "invalid_part": command_only}
	
	# 如果成功，返回解析出的数据
	#return { "success": true, "tool_name": json_data.tool_name, "arguments": json_data.arguments }
	
	# 使用 ToolCallValidator 进行严格校验（仅第一个 ```json 调用）
	var result: Dictionary = ToolCallValidator.validate_raw_tool_call(command_only)
	
	if result.success:
		return {
			"success": true,
			"tool_name": result.tool_call.tool_name,
			"arguments": result.tool_call.arguments
		}
	else:
		# 将 ToolCallValidator 的错误映射到旧有的 error_type 系统
		var error_type = "syntax_error"  # 默认
		var msg = result.error_message
		
		if msg.find("parse JSON") != -1:
			error_type = "invalid_json"
		elif (
			msg.find("arguments") != -1 or
			msg.find("field") != -1 or
			msg.find("context_type") != -1 or
			msg.find("path") != -1 or
			msg.find("Missing") != -1
		):
			error_type = "invalid_json_arguments"
		
		return {
			"success": false,
			"error_type": error_type,
			"invalid_part": command_only
		}


# 根据错误类型生成给AI的反馈信息。
static func handle_tool_call_error(_error_type: String, _error_data: Dictionary = {}) -> String:
	match _error_type:
		"syntax_error":
			return "[SYSTEM FEEDBACK - Tool Call Failed]\nYour command failed due to a syntax error."
		"invalid_json":
			return "[SYSTEM FEEDBACK - Tool Call Failed]\nThe JSON inside your <tool_call> tag is malformed."
		# ... (其他错误处理)
	return "[SYSTEM FEEDBACK] An unknown error occurred."
