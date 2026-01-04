extends RefCounted
class_name ToolRegistry


# 存储所有注册的工具实例: { "tool_name": AiToolInstance }
static var ai_tools: Dictionary = {}


# 加载默认工具集
static func load_default_tools() -> void:
	var tools_dir: String = "res://addons/godot_ai_chat/scripts/core/tools/"
	
	# 显式定义核心工具列表
	var tool_scripts: Array[String] = [
		"get_context_tool.gd",
		"get_current_date_tool.gd",
		"search_documents_tool.gd",
		"write_notebook_tool.gd"
	]
	
	print("[ToolRegistry] Loading tools...")
	
	# 避免重复加载日志刷屏，可以加个判断或者只在非空时注册
	# 这里简单处理：每次调用重新注册一遍，覆盖旧引用是安全的
	for script_name in tool_scripts:
		var path: String = tools_dir.path_join(script_name)
		
		if not FileAccess.file_exists(path):
			push_warning("[ToolRegistry] Tool script not found: %s" % path)
			continue
		
		var script: Resource = load(path)
		if script:
			var tool_instance = script.new()
			# 双重检查 —— 既查类型，也查方法
			if (tool_instance is AiTool) or (tool_instance.has_method("execute") and tool_instance.has_method("get_parameters_schema")):
				# 尝试获取名称，处理某些情况下 script.new() 后属性未初始化的问题
				var t_name = tool_instance.name if "name" in tool_instance else ""
				if t_name.is_empty() and tool_instance.has_method("get_tool_name"): # 备用方案
					t_name = tool_instance.call("get_tool_name")
				
				if not t_name.is_empty():
					register_tool(tool_instance)
				else:
					# 如果是 GDScript 实例，有时候需要手动从 script 里的 const 或默认值读
					# 这里简单处理：如果没名字，报个错
					if tool_instance.get("name"):
						register_tool(tool_instance)
					else:
						push_error("[ToolRegistry] Tool %s has no 'name' property." % script_name)


# 注册一个工具实例
static func register_tool(_tool: AiTool) -> void:
	var tool_name: String = _tool.name
	if tool_name.is_empty():
		push_error("[ToolRegistry] Cannot register tool with empty name.")
		return
	
	ai_tools[tool_name] = _tool
	print("[ToolRegistry] Registered tool: %s" % tool_name)


# 获取指定名称的工具
static func get_tool(_tool_name: String) -> AiTool:
	return ai_tools.get(_tool_name)


# 获取所有工具的定义列表 (供 AiServiceAdapter 调用)
static func get_all_tool_definitions(_for_gemini: bool = false) -> Array:
	var definitions: Array = []
	for tool in ai_tools.values():
		var schema: Dictionary = tool.get_parameters_schema()
		
		# Gemini 兼容性处理：将类型转换为大写
		if _for_gemini:
			schema = convert_schema_to_gemini(schema)
			
		definitions.append({
			"name": tool.name,
			"description": tool.description,
			"parameters": schema
		})
	return definitions


# 辅助函数：将 Schema 转换为 Gemini 格式 (递归处理)
static func convert_schema_to_gemini(_schema: Dictionary) -> Dictionary:
	var new_schema: Dictionary = _schema.duplicate(true)
	if new_schema.has("type") and new_schema["type"] is String:
		new_schema["type"] = new_schema["type"].to_upper()
	
	if new_schema.has("properties"):
		for prop_name in new_schema["properties"]:
			new_schema["properties"][prop_name] = convert_schema_to_gemini(new_schema["properties"][prop_name])
	return new_schema
