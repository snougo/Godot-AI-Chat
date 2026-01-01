@tool
extends Control
class_name ChatHub

# 存档目录常量
const ARCHIVE_DIR = "res://addons/godot_ai_chat/chat_archives/"

# --- 场景引用 ---
@onready var chat_ui: ChatUI = $ChatUI
@onready var network_manager: NetworkManager = $NetworkManager
@onready var chat_backend: ChatBackend = $ChatBackend
@onready var current_chat_window: CurrentChatWindow = $CurrentChatWindow

@onready var chat_list_container: VBoxContainer = $ChatUI/TabContainer/Chat/VBoxContainer/ChatDisplayView/ScrollContainer/ChatListContainer
@onready var chat_scroll_container: ScrollContainer = $ChatUI/TabContainer/Chat/VBoxContainer/ChatDisplayView/ScrollContainer

# 当前绑定的资源文件路径 (用于自动保存)
var current_history_path: String = ""


func _ready() -> void:
	# 确保目录存在
	if not DirAccess.dir_exists_absolute(ARCHIVE_DIR):
		DirAccess.make_dir_recursive_absolute(ARCHIVE_DIR)
	
	# 依赖注入
	chat_backend.network_manager = network_manager
	chat_backend.current_chat_window = current_chat_window
	current_chat_window.chat_list_container = chat_list_container
	current_chat_window.chat_scroll_container = chat_scroll_container
	
	# [新增] 强制加载工具，修复首次安装/脚本重载后工具丢失的问题
	ToolRegistry.load_default_tools()
	
	# 等待一帧让子节点 Ready
	await get_tree().process_frame
	
	# --- 信号连接 ---
	
	# 1. UI 操作
	chat_ui.send_button_pressed.connect(_on_user_send_message)
	chat_ui.stop_button_pressed.connect(_on_stop_requested)
	chat_ui.new_chat_button_pressed.connect(_create_new_session)
	chat_ui.reconnect_button_pressed.connect(network_manager.get_model_list)
	chat_ui.load_chat_button_pressed.connect(_load_session)
	chat_ui.settings_save_button_pressed.connect(network_manager.get_model_list)
	chat_ui.save_as_markdown_button_pressed.connect(_export_markdown)
	
	# 2. 模型与设置
	chat_ui.model_selection_changed.connect(func(name): network_manager.current_model_name = name)
	
	# 3. 网络事件 -> UI 反馈
	network_manager.get_model_list_request_started.connect(chat_ui.update_ui_state.bind(ChatUI.UIState.CONNECTING))
	network_manager.get_model_list_request_succeeded.connect(chat_ui.update_model_list)
	network_manager.get_model_list_request_failed.connect(chat_ui.on_get_model_list_request_failed)
	
	network_manager.new_chat_request_sending.connect(func(): chat_ui.update_ui_state(ChatUI.UIState.WAITING_RESPONSE))
	network_manager.new_stream_chunk_received.connect(_on_chunk_received)
	network_manager.chat_stream_request_completed.connect(_on_stream_completed)
	network_manager.chat_request_failed.connect(_on_chat_failed)
	
	# 4. 后端 Agent 事件
	chat_backend.tool_workflow_started.connect(chat_ui.update_ui_state.bind(ChatUI.UIState.TOOLCALLING))
	chat_backend.tool_workflow_failed.connect(_on_chat_failed)
	chat_backend.assistant_message_ready.connect(_on_assistant_reply_completed)
	chat_backend.tool_message_generated.connect(_on_tool_message_generated)
	
	# 5. Token 统计
	network_manager.chat_usage_data_received.connect(current_chat_window.update_token_usage)
	
	# --- 初始化 ---
	network_manager.get_model_list()
	_create_new_session() # 启动时自动新建一个会话


# --- 核心业务逻辑 ---

# 新建会话 (自动保存逻辑的核心)
func _create_new_session() -> void:
	# 1. 停止当前可能的生成
	_on_stop_requested()
	
	# 2. 生成新文件名
	var now = Time.get_datetime_dict_from_system(false)
	var filename = "chat_%d-%02d-%02d_%02d-%02d-%02d.tres" % [now.year, now.month, now.day, now.hour, now.minute, now.second]
	current_history_path = ARCHIVE_DIR.path_join(filename)
	
	# 3. 创建新资源并保存
	var new_history = ChatMessageHistory.new()
	var err = ResourceSaver.save(new_history, current_history_path)
	if err != OK:
		chat_ui.show_confirmation("Error: Failed to create chat file at %s" % current_history_path)
		return
	
	# 4. 绑定到窗口
	current_chat_window.load_history_resource(new_history)
	chat_ui.update_ui_state(ChatUI.UIState.IDLE, "New Chat Created")
	
	# 5. 监听资源变化以实现自动保存
	if not new_history.changed.is_connected(_auto_save_history):
		new_history.changed.connect(_auto_save_history)


# 自动保存回调
func _auto_save_history() -> void:
	if current_history_path.is_empty():
		return
	
	var history = current_chat_window.chat_history
	if history:
		ResourceSaver.save(history, current_history_path)


# 加载会话
func _load_session(filename: String) -> void:
	var path = ARCHIVE_DIR.path_join(filename)
	
	if not FileAccess.file_exists(path):
		chat_ui.show_confirmation("Error: File not found: %s" % path)
		return
	
	var history = ResourceLoader.load(path)
	if history is ChatMessageHistory:
		_on_stop_requested() # 停止当前
		current_history_path = path # 更新当前路径
		
		current_chat_window.load_history_resource(history)
		chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: %s" % filename)
		
		# 重新绑定自动保存
		if not history.changed.is_connected(_auto_save_history):
			history.changed.connect(_auto_save_history)
	else:
		chat_ui.show_confirmation("Error: Invalid resource type.")


# 用户点击发送
func _on_user_send_message(text: String) -> void:
	# 1. UI 立即响应 (乐观 UI)
	chat_ui.clear_user_input()
	current_chat_window.append_user_message(text)
	
	# 2. 准备上下文 [关键修改]
	# 使用 get_truncated_messages 获取符合轮次限制的消息列表
	var settings = ToolBox.get_plugin_settings()
	var context_history = current_chat_window.chat_history.get_truncated_messages(
		settings.max_chat_turns,
		settings.system_prompt
	)
	
	# 3. 发送请求
	network_manager.start_chat_stream(context_history)


# 收到第一个 Chunk 时，更新 UI 状态
func _on_chunk_received(chunk: Dictionary) -> void:
	if chat_ui.current_state == ChatUI.UIState.WAITING_RESPONSE:
		chat_ui.update_ui_state(ChatUI.UIState.RESPONSE_GENERATING)
	
	# [修改] 传入 provider
	current_chat_window.handle_stream_chunk(chunk, network_manager.current_provider)


# [新增] 回调函数：显示工具结果
func _on_tool_message_generated(msg: ChatMessage) -> void:
	# [修改] 传递 msg.tool_call_id
	current_chat_window.append_tool_message(msg.name, msg.content, msg.tool_call_id)


# [修改] 处理流结束 (关键防死循环逻辑)
func _on_stream_completed() -> void:
	# 1. 如果后端正在进行复杂的工作流，ChatHub 不要插手！
	# 让 ToolWorkflowManager 自己处理它的流结束事件
	if chat_backend.is_in_workflow:
		return
	
	# 2. 获取完整的助手消息
	var last_msg = current_chat_window.chat_history.get_last_message()
	
	if last_msg and last_msg.role == ChatMessage.ROLE_ASSISTANT:
		# 3. 交给 Backend 处理
		chat_backend.process_response(last_msg)
	else:
		chat_ui.update_ui_state(ChatUI.UIState.IDLE)


# 停止
func _on_stop_requested() -> void:
	network_manager.cancel_stream()
	chat_backend.cancel_workflow()
	chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Stopped")


# 聊天失败 (网络错误或 Agent 错误)
func _on_chat_failed(error_msg: String) -> void:
	chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Error") # 回到 IDLE 允许重试
	current_chat_window.append_error_message(error_msg) # 内联错误显示


# Agent 最终回复完成
func _on_assistant_reply_completed(final_msg: ChatMessage, additional_history: Array[ChatMessage]) -> void:
	# 将 Agent 产生的所有历史 (Tool Calls + Results) 同步到主历史
	current_chat_window.commit_agent_history(additional_history)
	chat_ui.update_ui_state(ChatUI.UIState.IDLE)


# 导出 Markdown
func _export_markdown(path: String) -> void:
	# 调用 ChatArchive 的逻辑 (需适配 ChatMessageHistory)
	var success = ChatArchive.save_to_markdown(current_chat_window.chat_history.messages, path)
	if success:
		chat_ui.show_confirmation("Exported to %s" % path)
