@tool
class_name ChatHub
extends Control

## 插件主控制器
## 负责依赖注入和组件组装。业务逻辑已拆分至 Controller 层。

# --- @onready Vars ---

@onready var _chat_ui: ChatUI = $ChatUI
@onready var _network_manager: NetworkManager = $NetworkManager
@onready var _agent_workflow: AgentWorkflow = $AgentWorkflow
@onready var _current_chat_window: CurrentChatWindow = $CurrentChatWindow

# --- Private Vars ---

var _session_manager: SessionManager
var _session_controller: ChatSessionController
var _interaction_controller: ChatInteractionController

# --- Built-in Functions ---

func _ready() -> void:
	# 1. 环境准备
	ToolRegistry.load_default_tools()
	
	# 2. 核心组件初始化
	_session_manager = SessionManager.new(_chat_ui, _current_chat_window)
	
	# 3. 依赖注入
	var chat_list_container: VBoxContainer = _chat_ui.get_chat_list_container()
	var chat_scroll_container: ScrollContainer = _chat_ui.get_chat_scroll_container()
	
	_agent_workflow.network_manager = _network_manager
	_agent_workflow.current_chat_window = _current_chat_window
	_current_chat_window.chat_list_container = chat_list_container
	_current_chat_window.chat_scroll_container = chat_scroll_container
	
	# 4. 初始化 Controllers
	_session_controller = ChatSessionController.new(_session_manager, _chat_ui, _current_chat_window)
	_interaction_controller = ChatInteractionController.new(_chat_ui, _network_manager, _agent_workflow, _current_chat_window, _session_manager)
	
	# 等待一帧让子节点 Ready
	await get_tree().process_frame
	
	# --- 信号连接 ---
	
	# 1. 会话控制信号
	_chat_ui.mouse_entered.connect(_on_chat_ui_mouse_entered) # 用于触发懒加载
	
	_chat_ui.new_chat_button_pressed.connect(func(): 
		_interaction_controller.handle_stop_requested() # 新建前先停止当前生成
		_session_controller.handle_new_chat()
	)
	_chat_ui.load_chat_button_pressed.connect(func(file):
		_interaction_controller.handle_stop_requested()
		_session_controller.handle_load_chat(file)
	)
	_chat_ui.delete_chat_button_pressed.connect(_session_controller.handle_delete_chat)
	_chat_ui.save_as_markdown_button_pressed.connect(_session_controller.handle_export_markdown)
	
	# 2. 交互控制信号
	_chat_ui.send_button_pressed.connect(_interaction_controller.handle_user_message)
	_chat_ui.stop_button_pressed.connect(_interaction_controller.handle_stop_requested)
	
	# 3. 设置与状态信号
	_chat_ui.reconnect_button_pressed.connect(_network_manager.get_model_list)
	_chat_ui.settings_save_button_pressed.connect(_network_manager.get_model_list)
	# 保存设置时也刷新轮数显示（因为 max_turns 可能改变）
	_chat_ui.settings_save_button_pressed.connect(_session_controller._update_turn_info) 
	
	_chat_ui.model_selection_changed.connect(func(model_name: String): _network_manager.current_model_name = model_name)
	
	# 4. 网络基础信号
	_network_manager.get_model_list_request_started.connect(_chat_ui.update_ui_state.bind(ChatUI.UIState.CONNECTING))
	_network_manager.get_model_list_request_succeeded.connect(_chat_ui.update_model_list)
	_network_manager.get_model_list_request_failed.connect(_chat_ui.get_model_list_request_failed)
	
	# 5. Token 统计信号
	_network_manager.chat_usage_data_received.connect(_chat_ui.update_token_usage_display)
	_current_chat_window.token_usage_updated.connect(_chat_ui.update_token_usage_display)


# --- Public Functions ---

func get_chat_ui() -> ChatUI:
	return _chat_ui


# --- Signal Callbacks ---

func _on_chat_ui_mouse_entered() -> void:
	# 懒加载逻辑：鼠标首次进入 UI 区域时才加载会话和模型列表
	if _chat_ui.mouse_entered.is_connected(_on_chat_ui_mouse_entered):
		AIChatLogger.debug("mouse_entered")
		_chat_ui.mouse_entered.disconnect(_on_chat_ui_mouse_entered)
		AIChatLogger.debug("[ChatHub] Initializing session and models...")
		
		# 1. 尝试加载会话
		_session_controller.auto_load_session()
		
		# 2. 稍作延迟后获取模型列表
		await get_tree().create_timer(0.5).timeout
		_network_manager.get_model_list()
