@tool
extends EditorPlugin


var chat_hub_packedscene: PackedScene = preload("res://addons/godot_ai_chat/ui/chat_hub.tscn")
var chat_hub_instance: Control = null
var chat_ui: ChatUI = null
# 用于UI注入的辅助变量，存储对新创建的分割容器的引用
#var _new_h_split_container: HSplitContainer = null
# 存储对原始编辑器左侧面板的引用，以便在插件退出时恢复布局
#var _original_left_panel = null
# 存储对原始编辑器右侧面板的引用，以便在插件退出时恢复布局
#var _original_right_panel = null


func _enter_tree() -> void:
	chat_hub_instance = chat_hub_packedscene.instantiate()
	chat_ui = chat_hub_instance.get_node_or_null("ChatUI")
	
	if is_instance_valid(chat_ui):
		chat_ui.ready.connect(_on_chat_ui_ready, CONNECT_ONE_SHOT)
	else:
		push_error("[Godot AI Chat] Can't find ChatUI Node")
		return
	
	# 确保 notebook.md 存在
	_ensure_notebook_exists()
	
	# 注册默认工具
	_register_default_tools()
	
	#inject_ui_async()
	
	# 新增：使用标准API将插件UI添加到编辑器右侧停靠栏
	# DOCK_SLOT_RIGHT_UL 表示右侧区域的左上方
	# Godot会自动使用 chat_hub_instance 节点的 `name` 属性作为停靠栏的标题
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, chat_hub_instance)
	print("[Godot AI Chat] Plugin UI injected into the right dock.")



func _exit_tree() -> void:
	# 在释放整个UI之前，先主动关闭网络线程，防止潜在的崩溃
	if is_instance_valid(chat_hub_instance):
		var network_manager: NetworkManager = chat_hub_instance.get_node_or_null("NetworkManager")
		if is_instance_valid(network_manager):
			var chat_streamed_request: ChatStreamedHTTPRequest = network_manager.get_node_or_null("ChatStreamedHTTPRequest")
			# 检查方法是否存在，确保安全调用
			if is_instance_valid(chat_streamed_request) and chat_streamed_request.has_method("thread_shutdown_and_wait"):
				# 这个调用是同步的，会阻塞当前线程直到后台网络线程完全结束
				chat_streamed_request.thread_shutdown_and_wait()
	
	# 恢复原始的编辑器布局
	#if is_instance_valid(_original_left_panel) and is_instance_valid(_new_h_split_container) and is_instance_valid(_original_right_panel):
		#var main_h_split: HSplitContainer = _new_h_split_container.get_parent()
		
		#if is_instance_valid(main_h_split):
			# 从新的分割容器中移除原始左面板
			#if _new_h_split_container.is_ancestor_of(_original_left_panel):
				#_new_h_split_container.remove_child(_original_left_panel)
			# 从新的分割容器中移除原始右面板
			#if _new_h_split_container.is_ancestor_of(_original_right_panel):
				#_new_h_split_container.remove_child(_original_right_panel)
			# 将原始面板重新添加回主分割容器
			#main_h_split.remove_child(_new_h_split_container)
			#main_h_split.add_child(_original_left_panel)
			#main_h_split.move_child(_original_left_panel, 0)
			#main_h_split.add_child(_original_right_panel)
			#main_h_split.move_child(_original_right_panel, 1)
			# 恢复分割条的默认状态和位置
			#main_h_split.drag_area_highlight_in_editor = false
			#main_h_split.split_offset = 400
			#print("[Godot AI Chat] Original ScriptEditor layout restored.")
		
		# 释放我们创建的分割容器
		#if is_instance_valid(_new_h_split_container):
			#_new_h_split_container.queue_free()
	
	# 使用标准API从停靠栏中移除插件UI
	if is_instance_valid(chat_hub_instance):
		remove_control_from_docks(chat_hub_instance)
	
	# 释放插件UI实例
	if is_instance_valid(chat_hub_instance):
		chat_hub_instance.queue_free()
	
	# 清理所有变量，防止内存泄漏
	print("[Godot AI Chat] Plugin disabled.")
	chat_hub_instance = null
	chat_ui = null
	#_new_h_split_container = null
	#_original_left_panel = null
	#_original_right_panel = null
	print("[Godot AI Chat] Cleanup complete.")


# 将插件UI注入到Godot编辑器的脚本编辑器视图中
#func inject_ui_async() -> void:
	# 确保UI只被注入一次
	#if is_instance_valid(chat_hub_instance) and chat_hub_instance.get_parent() != null:
		#push_error("[Godot AI Chat] UI is already injected.")
		#return
	
	# 查找脚本编辑器的主要水平分割容器
	#var main_h_split: HSplitContainer= find_main_h_split_container_with_certainty()
	#if is_instance_valid(main_h_split):
		#print("[Godot AI Chat] Editor is ready! Performing layout injection...")
		# 至少需要左右两个面板
		#if main_h_split.get_child_count() < 2:
			#push_warning("[Godot AI Chat] Main HSplitContainer does not have enough children, cannot inject.")
			#return
		
		# 保存原始的左右面板
		#_original_left_panel = main_h_split.get_child(0)
		#_original_right_panel = main_h_split.get_child(1)
		# 从主分割容器中移除它们
		#main_h_split.remove_child(_original_left_panel)
		#main_h_split.remove_child(_original_right_panel)
		# 创建一个新的水平分割容器，用于包裹原始的左右面板
		#_new_h_split_container = HSplitContainer.new()
		#_new_h_split_container.name = "NewScriptWrapperSplit"
		# 将原始面板添加到新的包裹容器中
		#_new_h_split_container.add_child(_original_left_panel)
		#_new_h_split_container.add_child(_original_right_panel)
		#_new_h_split_container.move_child(_original_left_panel, 0)
		#_new_h_split_container.move_child(_original_right_panel, 1)
		# 将新的包裹容器和我们的插件UI添加到主分割容器中，形成三栏布局
		#main_h_split.add_child(_new_h_split_container)
		#main_h_split.move_child(_new_h_split_container, 0)
		#main_h_split.add_child(chat_hub_instance)
		#main_h_split.move_child(chat_hub_instance, 1)
		# 设置布局参数
		#_new_h_split_container.split_offset = 400
		#chat_hub_instance.custom_minimum_size.x = 400
		#main_h_split.drag_area_highlight_in_editor = true
		#_new_h_split_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		
		#print("[Godot AI Chat] Three-column layout injected successfully!")


# 稳定地查找脚本编辑器的主要水平分割容器
#func find_main_h_split_container_with_certainty() -> HSplitContainer:
	#var script_editor = EditorInterface.get_script_editor()
	#if not is_instance_valid(script_editor):
		#return null
	# 1. 遍历 ScriptEditor 的直接子节点，寻找第一个 VBoxContainer
	#var main_vbox: VBoxContainer = null
	#for child in script_editor.get_children():
		#if child is VBoxContainer:
			#main_vbox = child
			# 找到了，停止循环
			#break
	#if not is_instance_valid(main_vbox):
		# 在这一帧没找到
		#return null
	# 2. 遍历 VBoxContainer 的直接子节点，寻找第一个 HSplitContainer
	#for child in main_vbox.get_children():
		#if child is HSplitContainer:
			# 找到了！返回最终目标！
			#return child
	
	#return null


# ChatUI节点发出ready信号后的回调处理函数
func _on_chat_ui_ready() -> void:
	if not is_instance_valid(chat_ui):
		push_error("[Godot AI Chat] ChatUI Node dones't exist, can't transmit editor filesystem.")
		return
	# 获取编辑器文件系统接口，并传递给ChatUI，以便其能够监听文件系统变化
	var editor_filesystem = get_editor_interface().get_resource_filesystem()
	if editor_filesystem:
		if chat_ui.has_method("initialize_editor_dependencies"):
			chat_ui.initialize_editor_dependencies(editor_filesystem)
		else:
			push_error("[Godot AI Chat] chat_ui.gd is missing the initialize_editor_dependencies method!")
	else:
		push_error("[Godot AI Chat] Could not get a valid EditorFileSystem in plugin.gd.")


# 注册默认工具的私有函数
func _register_default_tools() -> void:
	# 加载工具脚本
	var get_context_tool = load("res://addons/godot_ai_chat/scripts/tools/get_context_tool.gd")
	var search_docs_tool = load("res://addons/godot_ai_chat/scripts/tools/search_documents_tool.gd")
	var write_notebook_tool = load("res://addons/godot_ai_chat/scripts/tools/write_notebook_tool.gd")
	var get_current_date_tool = load("res://addons/godot_ai_chat/scripts/tools/get_current_date_tool.gd")
	
	# 实例化并注册
	if get_context_tool:
		ToolRegistry.register_tool(get_context_tool.new())
	else:
		push_error("[Godot AI Chat] Failed to load GetContextTool script.")
	
	if search_docs_tool:
		ToolRegistry.register_tool(search_docs_tool.new())
	else:
		push_error("[Godot AI Chat] Failed to load SearchDocsTool script.")
	
	if write_notebook_tool:
		ToolRegistry.register_tool(write_notebook_tool.new())
	else:
		push_error("[Godot AI Chat] Failed to load WriteNotebookTool script.")
	
	if get_current_date_tool:
		ToolRegistry.register_tool(get_current_date_tool.new())
	else:
		push_error("[Godot AI Chat] Failed to load GetCurrentDateTool script.")


# 确保 notebook 文件存在的辅助函数
func _ensure_notebook_exists() -> void:
	var notebook_path = "res://addons/godot_ai_chat/notebook.md"
	if not FileAccess.file_exists(notebook_path):
		var file = FileAccess.open(notebook_path, FileAccess.WRITE)
		if file:
			file.store_string("# AI Notebook\n\nThis file is used by the AI to store notes, plans, and code snippets.\n")
			file.close()
			# 刷新文件系统，让编辑器看到新文件
			var fs = EditorInterface.get_resource_filesystem()
			if fs:
				fs.scan()
