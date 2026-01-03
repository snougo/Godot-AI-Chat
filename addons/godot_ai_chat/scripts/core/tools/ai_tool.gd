@tool
extends RefCounted
class_name AiTool

# 工具的唯一标识符
var name: String = ""
# 工具的描述，提供给 AI 阅读
var description: String = ""


# [必须重写] 返回工具参数的 JSON Schema (OpenAI 格式)
# 只需要返回 "parameters" 字段对应的内容
func get_parameters_schema() -> Dictionary:
	return {"type": "object", "properties": {}}


# [必须重写] 执行工具逻辑
# args: AI 传入的参数字典
# context_provider: 上下文提供者实例 (依赖注入，来自 Godot Context Helper 插件)
# 返回: {"success": bool, "data": String}
func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	return {"success": false, "data": "Not implemented"}
