extends RefCounted
class_name ToolCallUtils


# Regex to find ```json ... ``` code blocks.
# (?si) flags: s (dotall) allows . to match newlines, i makes it case-insensitive.
const _JSON_BLOCK_REGEX = "(?si)```json\\s*(.*?)\\s*```"

# Regex to find a specific gpt-oss tool call format.
const _GPT_OSS_REGEX = "(?s)<\\|channel\\|>\\s*commentary\\s+to=([a-zA-Z0-9_.]+)\\s*<\\|constrain\\|>\\s*json\\s*<\\|message\\|>\\s*(\\{.*\\})"


#==============================================================================
# ## 内部辅助函数 ##
#==============================================================================

# 将包含多个串联 JSON 对象的字符串，拆分为单个 JSON 字符串的数组。
static func _split_concatenated_json(text: String) -> Array[String]:
	var json_objects: Array[String] = []
	var search_offset: int = 0
	
	while true:
		var object_start: int = text.find("{", search_offset)
		if object_start == -1:
			break # 当没有更多对象可以查找时退出循环。
		
		var brace_level: int = 1
		var object_end: int = -1
		
		for i in range(object_start + 1, text.length()):
			var char = text[i]
			if char == '{':
				brace_level += 1
			elif char == '}':
				brace_level -= 1
			
			if brace_level == 0:
				object_end = i
				break
		
		if object_end != -1:
			var json_str: String = text.substr(object_start, object_end - object_start + 1)
			json_objects.append(json_str)
			search_offset = object_end + 1
		else:
			break # 括号不匹配，停止处理以避免无限循环
	
	return json_objects


# 步骤1: 从原始文本中提取所有可能是工具调用的 JSON 字符串
static func _extract_raw_json_strings(content: String) -> Array[String]:
	var raw_strings: Array[String] = []
	
	# 策略 1: 优先尝试在原始文本中解析 gpt-oss 格式
	var gpt_oss_regex = RegEx.new()
	gpt_oss_regex.compile(_GPT_OSS_REGEX)
	var gpt_oss_match = gpt_oss_regex.search(content)
	if gpt_oss_match:
		raw_strings.append(gpt_oss_match.get_string(2).strip_edges())
		# 假设 gpt-oss 格式的调用只有一个，直接返回
		return raw_strings
	
	# 策略 2: 如果未找到 gpt-oss 格式，则清理文本并回退到标准的 ```json 代码块格式
	# 重构：调用 ToolBox 中的通用函数来移除 <think> 标签
	var cleaned_content: String = ToolBox.remove_think_tags(content)
	
	var json_block_regex = RegEx.new()
	json_block_regex.compile(_JSON_BLOCK_REGEX)
	var matches = json_block_regex.search_all(cleaned_content)
	for match in matches:
		var json_content = match.get_string(1).strip_edges()
		if not json_content.is_empty():
			raw_strings.append_array(_split_concatenated_json(json_content))
	
	return raw_strings


# 步骤2: 解析单个JSON字符串并验证其基本结构
static func _parse_and_validate_structure(json_string: String) -> Variant:
	# --- 优化: 使用JSON类的实例进行静默解析 ---
	var json_parser = JSON.new()
	var error = json_parser.parse(json_string)
	
	# 如果解析失败，则不打印错误，直接返回null
	if error != OK:
		return null
	
	var parsed_data = json_parser.get_data()
	
	# 验证是否是字典且包含必需的键
	if typeof(parsed_data) == TYPE_DICTIONARY and parsed_data.has("tool_name") and parsed_data.has("arguments"):
		return parsed_data
	
	return null


#==============================================================================
# ## 公共静态函数 ##
#==============================================================================

# 1. 判断模型的原始回应内容中是否包含格式正确的工具调用语句
# (便利性函数，适用于只判断不提取的场景)
static func has_tool_call(response_dict: Dictionary) -> bool:
	var content: String = response_dict.get("content", "")
	if content.is_empty():
		return false
	
	# 步骤1: 提取所有可能的JSON字符串
	var raw_json_strings = _extract_raw_json_strings(content)
	if raw_json_strings.is_empty():
		return false
	
	# 步骤2: 只要有一个字符串能被成功解析和验证，就返回 true
	for raw_string in raw_json_strings:
		if _parse_and_validate_structure(raw_string) != null:
			return true
	
	return false


# 2. 从模型的原始回应中将工具调用语句提取出来
# (核心函数，同时完成判断与提取)
static func tool_call_extract(response_dict: Dictionary) -> Array:
	var content: String = response_dict.get("content", "")
	var valid_tool_calls: Array = []
	if content.is_empty():
		return valid_tool_calls
	
	# 步骤1: 提取所有可能的JSON字符串
	var raw_json_strings = _extract_raw_json_strings(content)
	
	# 步骤2: 遍历并验证每一个，将有效的工具调用添加到结果数组
	for raw_string in raw_json_strings:
		var validated_call = _parse_and_validate_structure(raw_string)
		if validated_call != null:
			valid_tool_calls.append(validated_call)
	
	return valid_tool_calls


# 3. 将提取后的语句转化成接口可以识别的结构化数组
static func tool_call_converter(response_dict: Dictionary) -> Dictionary:
	# 创建一个深拷贝以避免修改原始字典
	var new_response = response_dict.duplicate(true)
	
	# --- 优化: 在函数内部直接调用提取逻辑 ---
	var extracted_calls: Array = tool_call_extract(response_dict)
	
	if extracted_calls.is_empty():
		return new_response # 如果没有工具调用，返回原始字典的拷贝
	
	var structured_calls: Array = []
	for i in range(extracted_calls.size()):
		var tool_call = extracted_calls[i]
		
		# 确保在处理前，字典包含预期的键 (虽然 extract_tool_calls 已保证，但作为公共接口，双重检查更安全)
		if not (tool_call is Dictionary and tool_call.has("tool_name") and tool_call.has("arguments")):
			push_warning("Skipping invalid item in extracted_calls array: %s" % str(tool_call))
			continue
		
		var tool_name = tool_call.get("tool_name", "unknown_tool")
		var tool_args = tool_call.get("arguments", {})
		
		# API 接口的 arguments 字段应该是一个 JSON 字符串
		var arguments_string: String = JSON.stringify(tool_args)
		
		structured_calls.append({
			"id": "call_id_%d" % i, # 使用一个更通用的 id
			"type": "function",
			"function": {
				"name": tool_name,
				"arguments": arguments_string
			}
		})
	
	# 将格式化后的工具调用数组添加到新字典中
	new_response["tool_calls"] = structured_calls
	
	return new_response


# 根据错误类型生成给AI的反馈信息。
static func handle_tool_call_error(_error_type: String, _error_data: Dictionary = {}) -> String:
	match _error_type:
		"unknown_tool":
			var tool_name = _error_data.get("tool_name", "N/A")
			return "[SYSTEM FEEDBACK - Tool Call Failed]\nThe tool you requested, '%s', does not exist. Please use available tools." % tool_name
		"unknown_context_type":
			var context_type = _error_data.get("context_type", "N/A")
			return "[SYSTEM FEEDBACK - Tool Call Failed]\nFor the 'get_context' tool, the context_type '%s' is not a valid option." % context_type
		"path_not_found":
			var path = _error_data.get("path", "N/A")
			return "[SYSTEM FEEDBACK - Tool Call Failed]\nThe specified path '%s' could not be found or accessed." % path
		"syntax_error":
			return "[SYSTEM FEEDBACK - Tool Call Failed]\nYour command failed due to a syntax error."
		"invalid_json":
			return "[SYSTEM FEEDBACK - Tool Call Failed]\nThe JSON inside your tool call is malformed."
		_:
			return "[SYSTEM FEEDBACK] An unknown error occurred during tool execution."
