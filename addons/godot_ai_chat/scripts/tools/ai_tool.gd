class_name AiTool
extends RefCounted

## AI 工具的基类
##
## 定义了 AI 工具必须实现的接口以及通用的写入安全检查逻辑。
##
## 写入检查分两道关卡，均由 ReadonlyZoneConfig 资源驱动（不再硬编码）：
## 1. 路径关卡：validate_path_safety() —— 管控区禁写，可配置豁免前缀
## 2. 格式关卡：validate_editable_path() —— 改写已有文件时，扩展名须在白名单内


# --- Public Vars ---

## 工具的唯一标识符
var tool_name: String = ""

## 工具的描述，提供给 AI 阅读
var tool_description: String = ""


# --- Public Functions ---

## [必须重写] 返回工具参数的 JSON Schema (OpenAI 格式)
## 只需要返回 "parameters" 字段对应的内容
func get_parameters_schema() -> Dictionary:
	return {"type": "object", "properties": {}}


## [必须重写] 执行工具逻辑
## [param p_args]: AI 传入的参数字典
## 返回: {"success": bool, "data": String}
func execute(_p_args: Dictionary) -> ToolResult:
	return ToolResult.fail("Not implemented")


## 统一的路径安全检查函数（第一道关卡：管控区）
## 返回空字符串表示安全，返回错误信息表示违规
func validate_path_safety(p_path: String) -> String:
	if p_path.is_empty():
		return "Path is empty."
	
	if not p_path.begins_with("res://"):
		return "Path must start with 'res://'."
	
	# 片断匹配与豁免前缀判断已迁至 ReadonlyZoneConfig：
	# 原实现在此处做路径标准化（把 res:// 换成 / 并补齐首尾斜杠，防止
	# "res://addons_test" 被误判为 "/addons/"），该逻辑现位于
	# ReadonlyZoneConfig._normalize_for_match()，语义保持不变。
	var config: ReadonlyZoneConfig = ReadonlyZoneConfig.get_config()
	var blocked_pattern: String = config.get_blocked_pattern(p_path)
	if not blocked_pattern.is_empty():
		return "**Security Error**: Operation denied on path '%s'. Because this path is read-only, write operations are prohibited. " % blocked_pattern
	
	return ""


## 统一的改写安全检查函数（路径关卡 + 格式关卡）
## 适用于「改写已有文本文件」这类工具（如 edit_file）
## [param p_path]: 目标文件路径
## 返回空字符串表示安全，返回错误信息表示违规
func validate_editable_path(p_path: String) -> String:
	var safety_err: String = validate_path_safety(p_path)
	if not safety_err.is_empty():
		return safety_err
	
	# 第二道关卡：扩展名白名单
	var config: ReadonlyZoneConfig = ReadonlyZoneConfig.get_config()
	var extension: String = p_path.get_extension().to_lower()
	if not config.is_extension_editable(extension):
		return "Error: '.%s' is not an editable text extension. Supported: %s" % [
			extension, config.get_editable_extensions_text()
		]
	
	return ""
