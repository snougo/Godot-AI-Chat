@tool
extends EditorPlugin

# 主场景路径
const CHAT_HUB_SCENE_PATH = "res://addons/godot_ai_chat/scene/chat_hub.tscn"
# 对话历史存档文件夹
const ARCHIVE_DIR = "res://addons/godot_ai_chat/chat_archives/"

# 插件主实例
var chat_hub_instance: Control = null


func _enter_tree() -> void:
	# 优先初始化文件系统环境
	# 这必须在实例化任何 UI 或逻辑脚本之前完成，以确保路径有效
	self._initialize_plugin_file_environment()
	
	# 加载并实例化主界面
	var scene: Resource = load(CHAT_HUB_SCENE_PATH)
	if not scene:
		push_error("[Godot AI Chat] Failed to load ChatHub scene at: " + CHAT_HUB_SCENE_PATH)
		return
	
	chat_hub_instance = scene.instantiate()
	# 将界面添加到编辑器停靠栏 (右侧左上区域)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, chat_hub_instance)
	
	# 注入编辑器依赖
	# 获取 ChatUI 节点并传递文件系统引用，用于文件选择器等功能
	var chat_ui: ChatUI = null
	if chat_hub_instance.has_method("get_chat_ui"):
		chat_ui = chat_hub_instance.get_chat_ui()
	else:
		# 兼容性兜底
		chat_ui = chat_hub_instance.get_node_or_null("ChatUI")
	
	if is_instance_valid(chat_ui):
		var editor_file_system: EditorFileSystem = get_editor_interface().get_resource_filesystem()
		chat_ui.initialize_editor_dependencies(editor_file_system)
	else:
		push_error("[Godot AI Chat] Could not find 'ChatUI' node in ChatHub scene.")


func _exit_tree() -> void:
	if is_instance_valid(chat_hub_instance):
		# 安全清理：强制停止所有正在进行的网络流和 Agent 工作流
		# 直接调用 ChatHub 的停止逻辑，它会级联取消 NetworkManager 和 ChatBackend
		if chat_hub_instance.has_method("_on_stop_requested"):
			chat_hub_instance._on_stop_requested()
		
		# 移除 UI
		remove_control_from_docks(chat_hub_instance)
		chat_hub_instance.queue_free()
	
	# 注意：ToolRegistry 是静态的，不需要显式清理，
	# 重新启用插件时会覆盖注册，这是安全的。
	
	print("[Godot AI Chat] Plugin disabled.")


# --- 内部辅助函数 ---

# 初始化插件需要的文件和文件夹
func _initialize_plugin_file_environment() -> void:
	var editor_file_system: EditorFileSystem = get_editor_interface().get_resource_filesystem()
	var need_scan: bool = false
	
	# 确保对话历史存档目录存在
	if not DirAccess.dir_exists_absolute(ARCHIVE_DIR):
		DirAccess.make_dir_recursive_absolute(ARCHIVE_DIR)
		need_scan = true
	
	# 确保插件配置文件存在
	# ToolBox.get_plugin_settings() 内部会创建文件并调用 update_file，
	# 但如果是初次创建，可能因为文件夹未扫描而失败，所以这里标记 scan
	var settings_path: String = "res://addons/godot_ai_chat/plugin_settings.tres"
	if not FileAccess.file_exists(settings_path):
		print("[Godot AI Chat] Settings file not found, creating default...")
		ToolBox.get_plugin_settings() # 这会创建默认文件
		need_scan = true
	
	# 如果创建了任何新目录或文件，执行一次完整的扫描
	# 这是唯一一次允许调用 scan() 的地方，因为它在插件加载初期运行
	if need_scan:
		print("[Godot AI Chat] Initializing plugin file environment (First Run Scan)...")
		editor_file_system.scan()
