@tool
class_name JSONRepairHelper
extends RefCounted

## JSON 修复工具
##
## 专门用于修复和清洗 LLM 输出的 JSON 数据的工具类。
## 能够处理 Markdown 包裹、未闭合的括号以及转义字符干扰。


# --- Public Functions ---

## 尝试从任意文本中提取并修复 JSON
## [return]: 修复后的 JSON 字符串。如果无法提取有效对象，返回 "{}"
static func repair_json(p_text: String) -> String:
	if p_text.is_empty():
		return "{}"
	
	# 1. 预处理：剥离 Markdown 代码块
	var clean_text: String = _strip_markdown(p_text)
	
	# 2. 尝试寻找最外层的 JSON 对象/数组边界
	# LLM 有时会在 JSON 前后说废话，我们需要找到第一个 { 或 [
	var start_idx: int = -1
	
	for i in range(clean_text.length()):
		var c: String = clean_text[i]
		if c == "{" or c == "[":
			start_idx = i
			break
	
	if start_idx == -1:
		return "{}" # 没找到 JSON 开始符
	
	# 从开始符截取后续内容
	var candidate: String = clean_text.substr(start_idx)
	
	# 3. 快速尝试：如果直接解析成功，就不折腾了
	if JSON.parse_string(candidate) != null:
		return candidate
	
	# 4. 基于栈的截断修复算法
	return _repair_truncated_json(candidate)


# --- Private Functions ---

# 剥离 ```json ... ``` 包裹
static func _strip_markdown(p_text: String) -> String:
	var result: String = p_text.strip_edges()
	
	if result.begins_with("```"):
		var newline_idx: int = result.find("\n")
		if newline_idx != -1:
			result = result.substr(newline_idx + 1)
		else:
			# 只有一行 ``` 的情况
			result = ""
		
		# 去除尾部的 ```
		result = result.strip_edges()
		if result.ends_with("```"):
			result = result.substr(0, result.length() - 3)
			
	return result.strip_edges()


# 核心算法：修复被截断的 JSON 字符串
static func _repair_truncated_json(p_json_str: String) -> String:
	var stack: Array[String] = []
	var in_string: bool = false
	var is_escaped: bool = false
	var result: String = p_json_str
	
	# 遍历字符串以维护栈状态
	for i in range(p_json_str.length()):
		var char: String = p_json_str[i]
		
		if is_escaped:
			is_escaped = false
			continue
		
		if char == "\\":
			is_escaped = true
			continue
		
		if char == "\"":
			in_string = not in_string
			continue
		
		if not in_string:
			if char == "{":
				stack.push_back("}")
			elif char == "[":
				stack.push_back("]")
			elif char == "}" or char == "]":
				if not stack.is_empty():
					var expected: String = stack.back()
					if char == expected:
						stack.pop_back()
					else:
						# 结构错乱（如 { ]），无法简单修复，放弃
						return "{}"
	
	# 遍历结束后的补全逻辑
	
	# 1. 如果还在字符串内，说明字符串被截断，先补全引号
	if in_string:
		result += "\""
	
	# 2. 逆序补全所有未闭合的括号
	while not stack.is_empty():
		result += stack.pop_back()
	
	# 修复被截断的 JSON 关键字
	result = _fix_truncated_keywords(result)
	
	return result


# 修复被截断的 JSON 关键字值（如 "nu" → "null", "tru" → "true" 等）
static func _fix_truncated_keywords(p_json: String) -> String:
	const TRUNCATED_MAP: Dictionary = {
		"n": "null", "nu": "null", "nul": "null",
		"t": "true", "tr": "true", "tru": "true",
		"f": "false", "fa": "false", "fal": "false", "fals": "false"
	}
	
	# 快速路径：已经是合法 JSON，无需修复
	if JSON.parse_string(p_json) != null:
		return p_json
	
	# 从末尾跳过空白和闭合括号，定位到最后一个值的末尾
	var end: int = p_json.length() - 1
	while end >= 0 and p_json[end] in " \t\n\r}]":
		end -= 1
	if end < 0:
		return p_json
	
	# 检查该位置是否在字符串引号内（在引号内的内容不处理）
	var in_str: bool = false
	var is_esc: bool = false
	for i in range(end + 1):
		if is_esc:
			is_esc = false
			continue
		var c: String = p_json[i]
		if c == "\\":
			is_esc = true
		elif c == "\"":
			in_str = not in_str
	
	if in_str:
		return p_json  # 在引号内，不应修改
	
	# 从 end 向前找到分隔符，提取潜在残缺值
	var start: int = end
	while start >= 0 and p_json[start] not in ":{,[":
		start -= 1
	
	var candidate: String = p_json.substr(start + 1, end - start).strip_edges()
	if TRUNCATED_MAP.has(candidate):
		return p_json.left(start + 1) + TRUNCATED_MAP[candidate] + p_json.right(end + 1)
	
	return p_json
