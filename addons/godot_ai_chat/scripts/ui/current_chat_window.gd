@tool
class_name CurrentChatWindow
extends Node

## 当前聊天窗口逻辑控制器
##
## 作为纯视图层，订阅 ChatMessageHistory 的数据变更信号进行渲染，
## 并负责流式渲染、可视性剔除与自动滚动。

# --- Signals ---

## 当 Token 使用量更新时发出
signal token_usage_updated(usage: Dictionary)

# --- Constants ---

const CULLING_INTERVAL: float = 0.2 # 每秒检测5次，足够平滑且低耗
## 消息块场景
const CHAT_MESSAGE_BLOCK_SCENE: PackedScene = preload(PluginPaths.CHAT_MESSAGE_BLOCK_SCENE)

# [自动滚动] 距底部多少像素以内视为"在底部"
const BOTTOM_THRESHOLD: float = 50.0

# --- Public Vars ---

## 消息列表容器引用
var chat_list_container: VBoxContainer
## 滚动容器引用
var chat_scroll_container: ScrollContainer
## 当前加载的聊天历史资源（唯一数据源）
var chat_history: ChatMessageHistory
## 当前使用的模型名称
var current_model_name: String = ""
var is_plugin_init: bool = false

# --- Private Vars ---

var _culling_timer: float = 0.0
var _is_loading: bool = false

# [自动滚动] 用户是否在底部，允许自动跟随
var _auto_scroll_enabled: bool = true
# [自动滚动] 防递归标志，区分程序滚动和用户操作
var _is_auto_scrolling: bool = false
# [自动滚动] 用于检测是否信号已经连接
var _scroll_signals_connected: bool = false

# 流式渲染临时状态：正在构建的 assistant 消息与对应 block
var _streaming_msg: ChatMessage = null
var _streaming_block: ChatMessageBlock = null
# 流式已渲染、待正式绑定的消息 instance_id 集合（用于跳过 message_added 的重复渲染）
var _stream_rendered_ids: Dictionary = {}


# --- Built-in Functions ---

func _process(delta: float) -> void:
	if not _scroll_signals_connected:
		_ensure_scroll_signal_connected()
	
	_culling_timer += delta
	if _culling_timer >= CULLING_INTERVAL:
		_culling_timer = 0.0
		_update_visibility_culling()


# --- Public Functions ---

## 加载聊天历史资源并刷新显示
func load_session_history_resource(p_session_history: ChatMessageHistory) -> void:
	if chat_history != null and chat_history.message_added.is_connected(_on_history_message_added):
		chat_history.message_added.disconnect(_on_history_message_added)
	
	chat_history = p_session_history
	
	if chat_history != null:
		chat_history.message_added.connect(_on_history_message_added)
	
	# 清理流式临时状态
	_streaming_msg = null
	_streaming_block = null
	_stream_rendered_ids.clear()
	
	_refresh_display()


## 清空当前会话视图（仅断开数据绑定并清空 UI，不删除数据）
func clear_session() -> void:
	if chat_history != null and chat_history.message_added.is_connected(_on_history_message_added):
		chat_history.message_added.disconnect(_on_history_message_added)
	
	chat_history = null
	_streaming_msg = null
	_streaming_block = null
	_stream_rendered_ids.clear()
	
	for child in chat_list_container.get_children():
		child.queue_free()


## 追加用户消息到历史（渲染由数据信号驱动）
func append_user_message(p_text: String, p_images: Array = []) -> void:
	chat_history.add_user_message(p_text, p_images)


## 追加错误消息到 UI（不入库）
func append_error_message(p_text: String) -> void:
	var block: ChatMessageBlock = _create_block()
	block.set_error(p_text)
	_scroll_to_bottom()


## 追加工具消息到历史（渲染由数据信号驱动）
func append_tool_message(p_tool_name: String, p_result_text: String, p_tool_call_id: String, p_image_data: PackedByteArray = PackedByteArray(), p_image_mime: String = "") -> void:
	var msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_TOOL, p_result_text, p_tool_name)
	msg.tool_call_id = p_tool_call_id
	
	if not p_image_data.is_empty():
		msg.add_image(p_image_data, p_image_mime)
	
	chat_history.add_message(msg)


## 处理流式数据块
## [param p_raw_chunk]: 原始数据块
## [param p_provider]: LLM 提供者实例，用于解析数据块
func handle_stream_chunk(p_raw_chunk: Dictionary, p_provider: BaseLLMProvider) -> void:
	# 1. 确保存在流式消息与对应 block
	if _streaming_msg == null:
		_streaming_msg = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, "")
	
	if _streaming_block == null:
		_streaming_block = _create_block()
		_streaming_block.start_stream(ChatMessage.ROLE_ASSISTANT, current_model_name)
		_scroll_to_bottom()
	
	# 2. 委托 Provider 解析并修改 _streaming_msg
	var ui_update: Dictionary = p_provider.process_stream_chunk(_streaming_msg, p_raw_chunk)
	
	# 3. UI 动画
	var content_delta: String = ui_update.get("content_delta", "")
	var reasoning_delta: String = ui_update.get("reasoning_delta", "")
	
	if not content_delta.is_empty():
		_streaming_block.append_chunk(content_delta)
	
	if not reasoning_delta.is_empty():
		_streaming_block.append_reasoning(reasoning_delta)
	
	# 4. 工具调用视觉反馈
	if not _streaming_msg.tool_calls.is_empty():
		for tc in _streaming_msg.tool_calls:
			_streaming_block.show_tool_call(tc)
	
	# 5. Token 统计
	var usage: Variant = ui_update.get("usage", null)
	if usage is Dictionary and not usage.is_empty():
		update_token_usage(usage)


## 结束流式接收：刷出缓冲并将流式消息入库
func flush_stream_buffer() -> void:
	if _streaming_block != null and _streaming_block.has_method("finish_stream"):
		_streaming_block.finish_stream()
	
	if _streaming_msg != null:
		var has_content: bool = (
			not _streaming_msg.content.is_empty()
			or not _streaming_msg.tool_calls.is_empty()
			or not _streaming_msg.reasoning_content.is_empty()
		)
		
		if has_content and chat_history != null:
			_stream_rendered_ids[_streaming_msg.get_instance_id()] = true
			chat_history.add_message(_streaming_msg)
		elif _streaming_block != null:
			# 空响应：移除空 block
			_streaming_block.queue_free()
		
		_streaming_msg = null
		_streaming_block = null


## 回滚未完成的消息（用于停止生成时）
func rollback_incomplete_message() -> void:
	# 清理流式临时状态
	_streaming_msg = null
	_streaming_block = null
	_stream_rendered_ids.clear()
	
	if chat_history == null or chat_history.messages.is_empty():
		_refresh_display()
		return
	
	var safety_count: int = 0
	
	# 纯数据回滚循环
	while not chat_history.messages.is_empty() and safety_count < 10:
		var last_msg: ChatMessage = chat_history.messages.back()
		
		# Tool 输出：删除并继续向上回滚
		if last_msg.role == ChatMessage.ROLE_TOOL:
			chat_history.messages.pop_back()
		# Assistant 消息（无论有无工具调用）：删除并停止
		elif last_msg.role == ChatMessage.ROLE_ASSISTANT:
			chat_history.messages.pop_back()
			break
		# User / System：停止
		else:
			break
		
		safety_count += 1
	
	_refresh_display()


## 提交 Agent 历史记录（占位符，逻辑已在 ChatHub 处理）
func commit_agent_history(_new_messages: Array[ChatMessage]) -> void:
	pass


## 更新 Token 使用量并发出信号
func update_token_usage(p_usage: Dictionary) -> void:
	if not p_usage.is_empty():
		token_usage_updated.emit(p_usage)


# --- Private Functions ---

# 数据信号回调：渲染新追加的消息
func _on_history_message_added(p_msg: ChatMessage) -> void:
	var msg_id: int = p_msg.get_instance_id()
	if _stream_rendered_ids.has(msg_id):
		_stream_rendered_ids.erase(msg_id)
		return
	
	_render_message(p_msg)
	_scroll_to_bottom()


# 渲染单条消息为 UI block
func _render_message(p_msg: ChatMessage) -> void:
	_add_block(p_msg.role, p_msg.content, true, p_msg.tool_calls, p_msg.images, p_msg.reasoning_content)


# 执行可视性剔除逻辑
func _update_visibility_culling() -> void:
	if _is_loading:
		return
	if not is_instance_valid(chat_scroll_container) or not is_instance_valid(chat_list_container):
		return
	
	# [安全检查] 如果容器高度为 0，说明布局还没准备好，跳过本次计算
	# 否则所有节点的 position 都是 0，会导致全部 resume
	if chat_list_container.size.y <= 1.0:
		return
	
	# 1. 获取视口范围
	# scroll_vertical 代表可视区域顶部的偏移量
	var scroll_offset: float = chat_scroll_container.scroll_vertical
	var viewport_height: float = chat_scroll_container.size.y
	
	# 2. 设置缓冲区 (Buffer)
	# 上下各预留 600 像素，确保快速滚动时不会看到空白
	var buffer: float = 400.0
	var visible_top: float = scroll_offset - buffer
	var visible_bottom: float = scroll_offset + viewport_height + buffer
	
	# --- Debug 统计变量 ---
	var total_count: int = 0
	var suspended_count: int = 0
	var visible_count: int = 0
	# --------------------
	
	# 3. 遍历并切换状态
	for child in chat_list_container.get_children():
		if child is ChatMessageBlock:
			total_count += 1 # 统计总数
			# VBoxContainer 中，子节点的 position.y 是相对于容器顶部的偏移
			var child_top: float = child.position.y
			var child_bottom: float = child_top + child.size.y
			
			# 判断是否与扩充后的视口相交
			# 如果 (子节点底部 < 视口顶部) 或 (子节点顶部 > 视口底部)，则完全在视口外
			if child_bottom < visible_top or child_top > visible_bottom:
				child.suspend_content()
				suspended_count += 1 # 统计挂起数
			else:
				child.resume_content()
				visible_count += 1 # 统计可见数
	
	# --- 打印 Debug 信息 ---
	# 只有当数据发生变化或者每隔一定时间打印一次，避免刷屏
	# 这里为了演示简单，我们只在总数大于 0 时打印
	if visible_count > 16:
		AIChatLogger.debug("Debug: Total: %d | Visible: %d | Suspended: %d" % [total_count, visible_count, suspended_count])
	
	# [调试] 如果卡死依然发生，请观察控制台输出
	# 正常情况下，151个消息块，suspended_count 应该在 140 以上
	#print("Culling: Suspended %d / %d" % [suspended_count, chat_list_container.get_child_count()])


# 刷新整个消息列表显示
func _refresh_display() -> void:
	_is_loading = true
	
	for c in chat_list_container.get_children():
		c.queue_free()
	await get_tree().process_frame
	
	if chat_history != null:
		for msg in chat_history.messages:
			if msg.role == ChatMessage.ROLE_SYSTEM:
				continue
			_render_message(msg)
			await get_tree().process_frame
	
	_is_loading = false
	await get_tree().process_frame
	await get_tree().process_frame
	_scroll_to_bottom()
	_update_visibility_culling()


# 添加一个消息块到 UI
func _add_block(p_role: String, p_content: String, p_instant: bool, p_tool_calls: Array = [], p_images: Array = [], p_reasoning: String = "") -> void:
	var block: ChatMessageBlock = _create_block()
	block.set_content(p_role, p_content, current_model_name if p_role == ChatMessage.ROLE_ASSISTANT else "", p_tool_calls, p_reasoning)
	
	for img in p_images:
		if img is Dictionary and img.has("data"):
			block.display_image(img.data, img.get("mime", "image/png"))


# 实例化一个新的消息块
func _create_block() -> ChatMessageBlock:
	var block: ChatMessageBlock = CHAT_MESSAGE_BLOCK_SCENE.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	chat_list_container.add_child(block)
	return block


# 获取列表中的最后一个消息块
func _get_last_block() -> ChatMessageBlock:
	if chat_list_container.get_child_count() == 0:
		return null
	
	return chat_list_container.get_child(chat_list_container.get_child_count() - 1) as ChatMessageBlock


# 滚动到列表底部
func _scroll_to_bottom() -> void:
	_auto_scroll_enabled = true
	await get_tree().process_frame
	await get_tree().process_frame
	if chat_scroll_container.get_v_scroll_bar():
		chat_scroll_container.scroll_vertical = chat_scroll_container.get_v_scroll_bar().max_value


# 即时滚动到底部（call_deferred 确保在布局更新后执行）
func _apply_auto_scroll() -> void:
	if not is_instance_valid(chat_scroll_container):
		return
	
	var sb: ScrollBar = chat_scroll_container.get_v_scroll_bar()
	if sb:
		chat_scroll_container.scroll_vertical = sb.max_value


# 确保 ScrollBar 的信号已连接（延迟连接，因为 ScrollBar 可能在节点初始化时尚未创建）
func _ensure_scroll_signal_connected() -> void:
	if not is_instance_valid(chat_scroll_container):
		return
	
	var sb := chat_scroll_container.get_v_scroll_bar()
	if not sb:
		return
	
	if not sb.changed.is_connected(_on_scroll_bar_changed):
		sb.changed.connect(_on_scroll_bar_changed)
	if not sb.value_changed.is_connected(_on_scroll_value_changed):
		sb.value_changed.connect(_on_scroll_value_changed)
	
	_scroll_signals_connected = true


# ScrollBar 属性变化时触发（max_value 增加等），自动跟随到底部
func _on_scroll_bar_changed() -> void:
	if _is_auto_scrolling or not _auto_scroll_enabled:
		return
	
	_is_auto_scrolling = true
	_apply_auto_scroll()
	_is_auto_scrolling = false


# ScrollBar 值变化时触发（用户手动滚动），更新自动滚动状态
func _on_scroll_value_changed(p_value: float) -> void:
	if _is_auto_scrolling:
		return  # 程序触发的，忽略
	if not is_instance_valid(chat_scroll_container):
		return
	var sb := chat_scroll_container.get_v_scroll_bar()
	if sb and sb.max_value > 0:
		var max_scroll: float = sb.max_value - sb.page
		if p_value >= max_scroll - BOTTOM_THRESHOLD:
			_auto_scroll_enabled = true
		else:
			_auto_scroll_enabled = false
