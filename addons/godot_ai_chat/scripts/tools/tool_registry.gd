extends RefCounted
class_name ToolRegistry


# 存储所有注册的工具实例: { "tool_name": AiToolInstance }
static var ai_tools: Dictionary = {}


# 加载默认工具集
static func load_default_tools() -> void:
	var tools_dir: String = "res://addons/godot_ai_chat/scripts/tools/"
	
	# 显式定义核心工具列表
	var tool_scripts: Array[String] = [
		"create_folder_tool.gd",
		"scene_tool/open_and_switch_scene_tool.gd",
		"scene_tool/get_current_active_scene_tool.gd",
		"scene_tool/get_node_property_tool.gd",
		"scene_tool/create_new_scene_tool.gd",
		"scene_tool/add_new_node_tool.gd",
		"scene_tool/set_node_property_tool.gd",
		"script_tool/get_current_active_script_tool.gd",
		"script_tool/create_new_script_tool.gd",
		"script_tool/fill_empty_script_tool.gd",
		"script_tool/disable_script_code_tool.gd",
		"script_tool/insert_script_code_tool.gd",
		"get_context_tool.gd",
		"get_current_date_tool.gd",
		"api_documents_search_tool.gd",
		"get_image_tool.gd",
		"notebook_tool.gd",
		"todo_list_tool.gd",
		"web_search_tool.gd"
	]
	
	print("[ToolRegistry] Loading tools...")
	
	# 每次调用前先清空，防止旧的无效引用残留
	ai_tools.clear()
	
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
			# 双重检查 —— 既查类型，也查方法 (Duck Typing)
			# 即使 AiTool 类型未注册(is AiTool 失败)，只要方法齐全也允许通过
			var is_valid_tool: bool = false
			
			if tool_instance is AiTool:
				is_valid_tool = true
			elif tool_instance.has_method("execute") and tool_instance.has_method("get_parameters_schema"):
				is_valid_tool = true
			
			if is_valid_tool:
				# 尝试获取名称，处理某些情况下 script.new() 后属性未初始化的问题
				var t_name: String = tool_instance.tool_name if "tool_name" in tool_instance else ""
				if t_name.is_empty() and tool_instance.has_method("get_tool_name"): # 备用方案
					t_name = tool_instance.call("get_tool_name")
				
				# 如果还没名字，尝试直接 get 属性 (针对纯 GDScript 实例)
				if t_name.is_empty():
					t_name = tool_instance.get("tool_name")
				
				if t_name and not t_name.is_empty():
					register_tool(tool_instance)
				else:
					push_error("[ToolRegistry] Tool %s has no 'name' property." % script_name)


# 注册一个工具实例
static func register_tool(_tool: Object) -> void:
	var tool_name: String = _tool.tool_name
	if tool_name == null or tool_name.is_empty():
		push_error("[ToolRegistry] Cannot register tool with empty name.")
		return
	
	ai_tools[tool_name] = _tool
	print("[ToolRegistry] Registered tool: %s" % tool_name)


# 获取指定名称的工具
static func get_tool(_tool_name: String) -> AiTool:
	return ai_tools.get(_tool_name)


# 获取所有工具的定义列表 (供 AiServiceAdapter 调用)
static func get_all_tool_definitions(_for_gemini: bool = false) -> Array:
	# 自动重试机制：如果列表为空，尝试重新加载
	# 这解决了首次安装插件未重启编辑器时，_ready 中注册失败的问题
	if ai_tools.is_empty():
		print("[ToolRegistry] Tool list is empty (first run?), attempting to reload default tools...")
		load_default_tools()
	
	var definitions: Array = []
	for tool in ai_tools.values():
		var schema: Dictionary = tool.get_parameters_schema()
		
		# Gemini 兼容性处理：将类型转换为大写
		if _for_gemini:
			schema = convert_schema_to_gemini(schema)
			
		definitions.append({
			"name": tool.tool_name,
			"description": tool.tool_description,
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
