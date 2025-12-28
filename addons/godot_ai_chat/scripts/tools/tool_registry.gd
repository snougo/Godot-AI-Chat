extends RefCounted
class_name ToolRegistry


# 存储所有注册的工具实例: { "tool_name": AiToolInstance }
static var _tools: Dictionary = {}


# 注册一个工具实例
static func register_tool(tool: AiTool) -> void:
	if tool.name.is_empty():
		push_error("[ToolRegistry] Cannot register tool with empty name.")
		return
	_tools[tool.name] = tool
	print("[ToolRegistry] Registered tool: %s" % tool.name)


# 获取指定名称的工具
static func get_tool(tool_name: String) -> AiTool:
	return _tools.get(tool_name)


# 获取所有工具的定义列表 (供 AiServiceAdapter 调用)
static func get_all_tool_definitions(for_gemini: bool = false) -> Array:
	var definitions: Array = []
	for tool in _tools.values():
		var schema = tool.get_parameters_schema()
		
		# Gemini 兼容性处理：将类型转换为大写
		if for_gemini:
			schema = _convert_schema_to_gemini(schema)
			
		definitions.append({
			"name": tool.name,
			"description": tool.description,
			"parameters": schema
		})
	return definitions


# 辅助函数：将 Schema 转换为 Gemini 格式 (递归处理)
static func _convert_schema_to_gemini(schema: Dictionary) -> Dictionary:
	var new_schema = schema.duplicate(true)
	if new_schema.has("type") and new_schema["type"] is String:
		new_schema["type"] = new_schema["type"].to_upper()
	
	if new_schema.has("properties"):
		for prop_name in new_schema["properties"]:
			new_schema["properties"][prop_name] = _convert_schema_to_gemini(new_schema["properties"][prop_name])
	return new_schema
