@tool
extends Control
class_name ChatHub

# 对话历史存档目录常量
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
# 状态锁，防止新建按钮连击导致逻辑错乱
var is_creating_new_chat: bool = false


func _ready() -> void:
	# 在这里注册工具，确保环境已稳定
	ToolRegistry.load_default_tools()
	
	# 确保目录存在（双重保险）
	if not DirAccess.dir_exists_absolute(ARCHIVE_DIR):
		DirAccess.make_dir_recursive_absolute(ARCHIVE_DIR)
	
	# 依赖注入
	chat_backend.network_manager = network_manager
	chat_backend.current_chat_window = current_chat_window
	current_chat_window.chat_list_container = chat_list_container
	current_chat_window.chat_scroll_container = chat_scroll_container
	
	# 等待一帧让子节点 Ready
	await get_tree().process_frame
	
	# --- 信号连接 ---
	
	# UI 操作
	chat_ui.send_button_pressed.connect(self._on_user_send_message)
	chat_ui.stop_button_pressed.connect(self._on_stop_requested)
	chat_ui.new_chat_button_pressed.connect(self._create_new_chat_history)
	chat_ui.reconnect_button_pressed.connect(network_manager.get_model_list)
	chat_ui.load_chat_button_pressed.connect(self._load_chat_history)
	chat_ui.settings_save_button_pressed.connect(network_manager.get_model_list)
	chat_ui.save_as_markdown_button_pressed.connect(self._export_markdown)
	
	# 模型与设置
	chat_ui.model_selection_changed.connect(func(model_name: String): network_manager.current_model_name = model_name)
	
	# 网络事件 -> UI 反馈
	network_manager.get_model_list_request_started.connect(chat_ui.update_ui_state.bind(ChatUI.UIState.CONNECTING))
	network_manager.get_model_list_request_succeeded.connect(chat_ui.update_model_list)
	network_manager.get_model_list_request_failed.connect(chat_ui.get_model_list_request_failed)
	
	# 网络事件 -> 发起对话
	network_manager.new_chat_request_sending.connect(chat_ui.update_ui_state.bind(ChatUI.UIState.WAITING_RESPONSE))
	network_manager.new_stream_chunk_received.connect(self._on_chunk_received)
	network_manager.chat_stream_request_completed.connect(self._on_stream_completed)
	network_manager.chat_request_failed.connect(self._on_chat_failed)
	
	# 后端 Agent 事件
	chat_backend.tool_workflow_started.connect(chat_ui.update_ui_state.bind(ChatUI.UIState.TOOLCALLING))
	chat_backend.tool_workflow_failed.connect(self._on_chat_failed)
	chat_backend.assistant_message_ready.connect(self._on_assistant_reply_completed)
	chat_backend.tool_message_generated.connect(self._on_tool_message_generated)
	
	# Token 统计
	# 依然保留 NetworkManager 的连接 (作为备份)，但直接连给 ChatUI
	if not network_manager.chat_usage_data_received.is_connected(chat_ui.update_token_cost_display):
		network_manager.chat_usage_data_received.connect(chat_ui.update_token_cost_display)
	
	# 连接 CurrentChatWindow 的新信号到 ChatUI
	if not current_chat_window.token_usage_updated.is_connected(chat_ui.update_token_cost_display):
		current_chat_window.token_usage_updated.connect(chat_ui.update_token_cost_display)
	
	# --- 初始化 ---
	network_manager.get_model_list()


# --- 核心业务逻辑 ---

# 新建会话
func _create_new_chat_history() -> void:
	# 如果正在创建中，直接忽略本次请求
	if is_creating_new_chat:
		return
	
	# 如果用户手快已经手动点了新建或加载，就不自动创建了
	if current_history_path.is_empty() or is_creating_new_chat == false:
		is_creating_new_chat = true
		
		# 停止当前可能的生成
		self._on_stop_requested()
		
		# 即使 _ready 里检查过，这里再检查一次，防止用户运行时删除了文件夹
		if not DirAccess.dir_exists_absolute(ARCHIVE_DIR):
			DirAccess.make_dir_recursive_absolute(ARCHIVE_DIR)
		
		# 文件名去重逻辑
		var now_time: Dictionary = Time.get_datetime_dict_from_system(false)
		var base_filename: String = "chat_%d-%02d-%02d_%02d-%02d-%02d" % [now_time.year, now_time.month, now_time.day, now_time.hour, now_time.minute, now_time.second]
		var extension_type: String = ".tres"
		var final_path: String = ARCHIVE_DIR.path_join(base_filename + extension_type)
		
		# 如果同一秒内已存在文件，则追加序号 (例如 _1, _2)
		var counter: int = 1
		while FileAccess.file_exists(final_path):
			final_path = ARCHIVE_DIR.path_join("%s_%d%s" % [base_filename, counter, extension_type])
			counter += 1
		current_history_path = final_path
		
		# 创建新资源并保存
		var new_history: ChatMessageHistory = ChatMessageHistory.new()
		var err: Error = ResourceSaver.save(new_history, current_history_path)
		if err != OK:
			chat_ui.show_confirmation("Error: Failed to create chat file at %s" % current_history_path)
			return
		
		# 增加短暂延迟，防止文件写入与编辑器扫描的 Race Condition
		await get_tree().create_timer(0.2).timeout
		
		# 此时文件已物理写入磁盘。
		# 我们通过 ToolBox 精确通知编辑器更新【这一个文件】。
		ToolBox.update_editor_filesystem(current_history_path)
		
		# [修复] 重置 Token 显示
		chat_ui.reset_token_cost_display()
		
		# 绑定到窗口
		current_chat_window.load_history_resource(new_history)
		chat_ui.update_ui_state(ChatUI.UIState.IDLE, "New Chat Created")
		
		# 解锁
		is_creating_new_chat = false
		
		# 监听资源变化以实现自动保存
		if not new_history.changed.is_connected(self._auto_save_history):
			new_history.changed.connect(self._auto_save_history)


# 自动保存回调
func _auto_save_history() -> void:
	if current_history_path.is_empty():
		return
	
	var chat_history: ChatMessageHistory = current_chat_window.chat_history
	if chat_history:
		ResourceSaver.save(chat_history, current_history_path)


# 加载会话
func _load_chat_history(filename: String) -> void:
	var path: String = ARCHIVE_DIR.path_join(filename)
	
	if not FileAccess.file_exists(path):
		chat_ui.show_confirmation("Error: File not found: %s" % path)
		return
	
	var chat_history: Resource = ResourceLoader.load(path)
	if chat_history is ChatMessageHistory:
		self._on_stop_requested() # 停止当前
		current_history_path = path # 更新当前路径
		
		# [修复] 加载新存档前，重置 Token 显示为 0
		# 因为存档文件(.tres)里不保存 Token 数据，所以只能重置
		chat_ui.reset_token_cost_display()
		
		current_chat_window.load_history_resource(chat_history)
		chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Loaded: %s" % filename)
		
		# 重新绑定自动保存
		if not chat_history.changed.is_connected(self._auto_save_history):
			chat_history.changed.connect(self._auto_save_history)
	else:
		chat_ui.show_confirmation("Error: Invalid resource type.")


# --- 回调函数 ---

# 用户点击发送
func _on_user_send_message(text: String) -> void:
	# 增加空状态检查
	# 检查路径是否为空，或者 CurrentChatWindow 中的 chat history 是否为空
	if current_history_path.is_empty() or current_chat_window.chat_history == null:
		chat_ui.show_confirmation("No chat active.\nPlease click 'New Button' or 'Load Button' to start.")
		return
	
	# UI 立即响应 (乐观 UI)
	chat_ui.clear_user_input()
	current_chat_window.append_user_message(text)
	
	# 准备上下文
	# 使用 get_truncated_messages 获取符合轮次限制的消息列表
	var settings = ToolBox.get_plugin_settings()
	var context_history: Array[ChatMessage] = current_chat_window.chat_history.get_truncated_messages(
		settings.max_chat_turns,
		settings.system_prompt
	)
	
	# 发送请求
	network_manager.start_chat_stream(context_history)


# 收到第一个 Chunk 时，更新 UI 状态
func _on_chunk_received(chunk: Dictionary) -> void:
	if chat_ui.current_state == ChatUI.UIState.WAITING_RESPONSE:
		chat_ui.update_ui_state(ChatUI.UIState.RESPONSE_GENERATING)
	
	# 传入 provider
	current_chat_window.handle_stream_chunk(chunk, network_manager.current_provider)


# 显示工具结果
func _on_tool_message_generated(msg: ChatMessage) -> void:
	# 传递 msg.tool_call_id
	current_chat_window.append_tool_message(msg.name, msg.content, msg.tool_call_id)


# 处理流结束 (关键防死循环逻辑)
func _on_stream_completed() -> void:
	# 如果后端正在进行复杂的工作流，ChatHub 不要插手！
	# 让 ToolWorkflowManager 自己处理它的流结束事件
	if chat_backend.is_in_workflow:
		return
	
	# 获取完整的助手消息
	var last_msg: ChatMessage = current_chat_window.chat_history.get_last_message()
	
	if last_msg and last_msg.role == ChatMessage.ROLE_ASSISTANT:
		# 交给 Backend 处理
		chat_backend.process_response(last_msg)
	else:
		chat_ui.update_ui_state(ChatUI.UIState.IDLE)


# 停止
func _on_stop_requested() -> void:
	network_manager.cancel_stream()
	chat_backend.cancel_workflow()
	
	# 用户停止时，也要保存当前已经生成的内容
	if current_chat_window.chat_history:
		current_chat_window.chat_history.emit_changed()
	
	chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Stopped")


# 聊天失败 (网络错误或 Agent 错误)
func _on_chat_failed(error_msg: String) -> void:
	chat_ui.update_ui_state(ChatUI.UIState.IDLE, "Error") # 回到 IDLE 允许重试
	current_chat_window.append_error_message(error_msg) # 内联错误显示


# Agent 最终回复完成
func _on_assistant_reply_completed(final_msg: ChatMessage, additional_history: Array[ChatMessage]) -> void:
	# 将 Agent 产生的所有历史 (Tool Calls + Results) 同步到主历史
	current_chat_window.commit_agent_history(additional_history)
	
	# 显式触发 changed 信号，强制将最终完整的对话内容写入磁盘
	if current_chat_window.chat_history:
		current_chat_window.chat_history.emit_changed()
	
	chat_ui.update_ui_state(ChatUI.UIState.IDLE)


# 导出 Markdown
func _export_markdown(path: String) -> void:
	# 调用 ChatArchive 的逻辑 (需适配 ChatMessageHistory)
	var success: bool = ChatArchive.save_to_markdown(current_chat_window.chat_history.messages, path)
	if success:
		chat_ui.show_confirmation("Exported to %s" % path)
