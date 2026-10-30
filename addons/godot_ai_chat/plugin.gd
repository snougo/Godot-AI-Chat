@tool
extends EditorPlugin


# --- Constants ---

# 主场景路径
const CHAT_HUB_SCENE_PATH: String = "res://addons/godot_ai_chat/scene/chat_hub.tscn"

# 插件图标
const PLUGIN_ICON: Texture2D = preload("res://addons/godot_ai_chat/assets/icons/plugin_icon.svg")

# 用于注入游戏运行时的debug脚本
const GameDebugSessionScript := preload("res://addons/godot_ai_chat/scripts/tools/debug_tool/game_debug_session.gd")

# 主 UI 控制器节点
const AIChatUI = preload("res://addons/godot_ai_chat/scripts/ui/chat_ui.gd")

# 导出忽略脚本
const GodotAIChatExportPluginScript := preload("res://addons/godot_ai_chat/godot_ai_chat_export_plugin.gd")


# --- Private Vars ---

# 插件主实例
var _chat_hub_instance: Control = null
# EditorDock 容器
var _godot_ai_chat_dock: EditorDock = null
# 导出自定义插件实例（用于从导出包中排除本插件）
var _export_plugin: EditorExportPlugin = null


# --- Built-in Functions ---

func _enter_tree() -> void:
	# 优先初始化文件系统环境
	# 这必须在实例化任何 UI 或逻辑脚本之前完成，以确保路径有效
	self._initialize_plugin_file_environment()
	
	GameDebugSessionScript.register(self)
	
	# 注册导出自定义插件：导出项目时自动排除本插件目录
	_export_plugin = GodotAIChatExportPluginScript.new()
	add_export_plugin(_export_plugin)
	
	# 加载并实例化主界面
	var scene: Resource = load(CHAT_HUB_SCENE_PATH)
	if not scene:
		AIChatLogger.error("[Godot AI Chat] Failed to load AIChatHub scene at: " + CHAT_HUB_SCENE_PATH)
		return
	
	_chat_hub_instance = scene.instantiate()
	
	# 将界面添加到编辑器停靠栏(旧版API方法)
	#add_control_to_dock(DOCK_SLOT_LEFT_UL, _chat_hub_instance)
	
	# 创建 EditorDock 容器并配置(新版API方法)
	_godot_ai_chat_dock = EditorDock.new()
	_godot_ai_chat_dock.title = "Godot AI Chat"
	_godot_ai_chat_dock.dock_icon = PLUGIN_ICON
	_godot_ai_chat_dock.default_slot = EditorDock.DOCK_SLOT_RIGHT_UL
	_godot_ai_chat_dock.add_child(_chat_hub_instance)
	add_dock(_godot_ai_chat_dock)
	
	# 注入编辑器依赖
	# 获取 AIChatUI 节点并传递文件系统引用，用于文件选择器等功能
	var chat_ui: AIChatUI = null
	if _chat_hub_instance.has_method("get_chat_ui"):
		chat_ui = _chat_hub_instance.get_chat_ui()
	else:
		# 兼容性兜底
		chat_ui = _chat_hub_instance.get_node_or_null("ChatUI")
	
	if is_instance_valid(chat_ui):
		var editor_file_system: EditorFileSystem = get_editor_interface().get_resource_filesystem()
		chat_ui.initialize_editor_dependencies(editor_file_system)
	else:
		AIChatLogger.error("[Godot AI Chat] Could not find 'ChatUI' node in AIChatHub scene.")


func _exit_tree() -> void:
	if is_instance_valid(_chat_hub_instance):
		# 安全清理：强制停止所有正在进行的网络流和 Agent 工作流
		# 直接调用 AIChatHub 的停止逻辑，它会级联取消 AIChatNetworkManager 和 ChatBackend
		if _chat_hub_instance.has_method("_on_stop_requested"):
			_chat_hub_instance._on_stop_requested()
		
		# 移除 UI(旧版API方法)
		#remove_control_from_docks(_chat_hub_instance)
		#_chat_hub_instance.queue_free()
		
		# 移除 Dock(新版API方法)
		if is_instance_valid(_godot_ai_chat_dock):
			remove_dock(_godot_ai_chat_dock)
			_godot_ai_chat_dock.queue_free()
			_godot_ai_chat_dock = null
	
	# 注意：ToolRegistry 是静态的，不需要显式清理，
	# 重新启用插件时会覆盖注册，这是安全的。
	
	GameDebugSessionScript.unregister(self)
	
	# 注销导出自定义插件
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null
	
	AIChatLogger.info("[Godot AI Chat] Plugin disabled.")


# --- Private Functions ---

# 初始化插件需要的文件和文件夹
func _initialize_plugin_file_environment() -> void:
	
	# 确保插件配置文件存在
	# 如果不存在则创建
	if not FileAccess.file_exists(PluginPaths.SETTINGS_PATH):
		# ToolBox.get_plugin_settings() 内部会创建对应的文件夹和默认的插件设置文件并调用 update_file
		ToolBox.get_plugin_settings() # 这会创建默认文件
		AIChatLogger.info("[Godot AI Chat] Settings file not found, creating default...")
	
		# 确保对话存档目录存在
	if not DirAccess.dir_exists_absolute(PluginPaths.SESSION_DIR):
		DirAccess.make_dir_recursive_absolute(PluginPaths.SESSION_DIR)
		await get_tree().create_timer(1.0).timeout
		
		var editor_file_system: EditorFileSystem = get_editor_interface().get_resource_filesystem()
		editor_file_system.scan()
		AIChatLogger.info("[Godot AI Chat] Initializing plugin file environment (First Run Scan)...")
