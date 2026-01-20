@tool
class_name JSONRepairHelper
extends RefCounted

## 专门用于修复和清洗 LLM 输出的 JSON 数据的工具类。
## 能够处理 Markdown 包裹、未闭合的括号以及转义字符干扰。


## 尝试从任意文本中提取并修复 JSON
## [return]: 修复后的 JSON 字符串。如果无法提取有效对象，返回 "{}"
static func repair_json(text: String) -> String:
	if text.is_empty():
		return "{}"
	
	# 1. 预处理：剥离 Markdown 代码块
	var clean_text: String = _strip_markdown(text)
	
	# 2. 尝试寻找最外层的 JSON 对象/数组边界
	# LLM 有时会在 JSON 前后说废话，我们需要找到第一个 { 或 [
	var start_idx: int = -1
	var first_char: String = ""
	
	for i in range(clean_text.length()):
		var c: String = clean_text[i]
		if c == "{" or c == "[":
			start_idx = i
			first_char = c
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


## 剥离 ```json ... ``` 包裹
static func _strip_markdown(text: String) -> String:
	var result: String = text.strip_edges()
	
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


## 核心算法：修复被截断的 JSON 字符串
static func _repair_truncated_json(json_str: String) -> String:
	var stack: Array[String] = []
	var in_string: bool = false
	var is_escaped: bool = false
	var result: String = json_str
	
	# 遍历字符串以维护栈状态
	for i in range(json_str.length()):
		var char: String = json_str[i]
		
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
		
	return result
