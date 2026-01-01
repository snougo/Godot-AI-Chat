@tool
extends EditorPlugin

# 主场景路径
const CHAT_HUB_SCENE_PATH = "res://addons/godot_ai_chat/ui/chat_hub.tscn"
# 笔记本文件路径
const NOTEBOOK_PATH = "res://addons/godot_ai_chat/notebook.md"

# 插件主实例
var chat_hub_instance: Control = null


func _enter_tree() -> void:
	# 1. 加载并实例化主界面
	var scene = load(CHAT_HUB_SCENE_PATH)
	if not scene:
		push_error("[Godot AI Chat] Failed to load ChatHub scene at: " + CHAT_HUB_SCENE_PATH)
		return
		
	chat_hub_instance = scene.instantiate()
	
	# 2. 将界面添加到编辑器停靠栏 (右侧左上区域)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, chat_hub_instance)
	
	# 3. 注入编辑器依赖
	# 获取 ChatUI 节点并传递文件系统引用，用于文件选择器等功能
	var chat_ui = chat_hub_instance.get_node_or_null("ChatUI")
	if is_instance_valid(chat_ui):
		var editor_fs = get_editor_interface().get_resource_filesystem()
		chat_ui.initialize_editor_dependencies(editor_fs)
	else:
		push_error("[Godot AI Chat] Could not find 'ChatUI' node in ChatHub scene.")
	
	# 4. 初始化辅助功能
	_ensure_notebook_exists()
	_register_default_tools()
	
	print("[Godot AI Chat] Plugin initialized.")


func _exit_tree() -> void:
	if is_instance_valid(chat_hub_instance):
		# 1. 安全清理：强制停止所有正在进行的网络流和 Agent 工作流
		# 直接调用 ChatHub 的停止逻辑，它会级联取消 NetworkManager 和 ChatBackend
		if chat_hub_instance.has_method("_on_stop_requested"):
			chat_hub_instance._on_stop_requested()
		
		# 2. 移除 UI
		remove_control_from_docks(chat_hub_instance)
		chat_hub_instance.queue_free()
	
	# 注意：ToolRegistry 是静态的，不需要显式清理，
	# 重新启用插件时会覆盖注册，这是安全的。
	
	print("[Godot AI Chat] Plugin disabled.")


# --- 内部辅助函数 ---

func _register_default_tools() -> void:
	# 动态加载工具脚本并注册
	var tools_dir = "res://addons/godot_ai_chat/scripts/core/tools/"
	var tool_scripts = [
		"get_context_tool.gd",
		"get_current_date_tool.gd",
		"search_documents_tool.gd",
		"write_notebook_tool.gd"
	]
	
	for script_name in tool_scripts:
		var path = tools_dir.path_join(script_name)
		var script = load(path)
		if script:
			# 实例化工具并注册
			var tool_instance = script.new()
			ToolRegistry.register_tool(tool_instance)
		else:
			push_error("[Godot AI Chat] Failed to load tool script: %s" % path)


func _ensure_notebook_exists() -> void:
	if not FileAccess.file_exists(NOTEBOOK_PATH):
		var file = FileAccess.open(NOTEBOOK_PATH, FileAccess.WRITE)
		if file:
			file.store_string("# AI Notebook\n\nThis file is used by the AI to store notes, plans, and code snippets.\n")
			file.close()
			# 刷新文件系统，让编辑器看到新文件
			var fs = get_editor_interface().get_resource_filesystem()
			if fs:
				fs.scan()
