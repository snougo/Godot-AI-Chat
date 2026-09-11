@tool
class_name CurrentChatWindow
extends Node

## 当前聊天窗口逻辑控制器
##
## 作为纯视图层，订阅 ChatMessageHistory 的数据变更信号进行渲染，
## 并负责流式渲染、可视性剔除与自动滚动。
##
## 职责边界：
## 1. 数据的增删一律由 ChatMessageHistory 负责，本类不得直接改写其内容；
## 2. 协议解析由 Provider 负责，本类只消费协议无关的 LLMStreamDelta；
## 3. 数据落地由 StreamMessageAssembler 负责，本类只驱动 UI 动画。


# --- Signals ---

## 当 Token 使用量更新时发出
signal token_usage_updated(usage: Dictionary)


# --- Constants ---

const CULLING_INTERVAL: float = 0.2 # 每秒检测5次，足够平滑且低耗
## 消息块场景
const CHAT_MESSAGE_BLOCK_SCENE: PackedScene = preload(PluginPaths.CHAT_MESSAGE_BLOCK_SCENE)
## [自动滚动] 距底部多少像素以内视为"在底部"
const BOTTOM_THRESHOLD: float = 50.0
## 可视性剔除缓冲区（像素）：上下各预留，确保快速滚动时不会看到空白
const CULLING_BUFFER: float = 400.0
## 剔除调试输出的可见块数量阈值（低于该值不打印，避免刷屏）
const CULLING_DEBUG_THRESHOLD: int = 16


# --- Public Vars ---

## 消息列表容器引用
var chat_list_container: VBoxContainer
## 滚动容器引用
var chat_scroll_container: ScrollContainer
## 当前加载的聊天历史资源（唯一数据源）
var chat_history: ChatMessageHistory
## 当前使用的模型名称（用于助手消息标题展示）
var current_model_name: String = ""


# --- Private Vars ---

var _culling_timer: float = 0.0
var _is_loading: bool = false
# 重绘期间又被请求重绘时置位，待当前重绘结束后补做一次
var _refresh_pending: bool = false

# [自动滚动] 用户是否在底部，允许自动跟随
var _auto_scroll_enabled: bool = true
# [自动滚动] 防递归标志，区分程序滚动和用户操作
var _is_auto_scrolling: bool = false
# [自动滚动] 用于检测是否信号已经连接
var _scroll_signals_connected: bool = false

# 流式装配器：持有正在构建的助手消息，消费 Provider 产出的 LLMStreamDelta
var _assembler: StreamMessageAssembler = StreamMessageAssembler.new()
# 正在渲染的流式消息块
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
	_unbind_history()
	
	chat_history = p_session_history
	
	if chat_history != null:
		chat_history.message_added.connect(_on_history_message_added)
		chat_history.turn_rolled_back.connect(refresh_display)
	
	# 清理流式临时状态
	discard_streaming_message()
	refresh_display()


## 清空当前会话视图（仅断开数据绑定并清空 UI，不删除数据）
func clear_session() -> void:
	_unbind_history()
	
	chat_history = null
	discard_streaming_message()
	
	for child: Node in chat_list_container.get_children():
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


## 处理单个流式数据块
## [param p_raw_chunk]: 原始数据块
## [param p_provider]: LLM 提供者实例，用于把数据块翻译为协议无关增量
func handle_stream_chunk(p_raw_chunk: Dictionary, p_provider: BaseLLMProvider) -> void:
	# 1. 确保存在正在渲染的流式块（全量重绘可能已释放旧块）
	_ensure_streaming_block()
	
	# 2. 协议 → 增量（Provider 侧，不接触数据层）
	var delta: LLMStreamDelta = p_provider.parse_stream_chunk(p_raw_chunk)
	
	# 3. 增量 → 数据（装配器侧）
	_assembler.apply(delta)
	
	# 4. 增量 → UI 动画
	if not delta.content_delta.is_empty():
		_streaming_block.append_chunk(delta.content_delta)
	
	if not delta.reasoning_delta.is_empty():
		_streaming_block.append_reasoning(delta.reasoning_delta)
	
	# 5. 工具调用视觉反馈
	var streaming_msg: ChatMessage = _assembler.get_message()
	if streaming_msg != null and not streaming_msg.tool_calls.is_empty():
		for tc: Dictionary in streaming_msg.tool_calls:
			_streaming_block.show_tool_call(tc)
	
	# 6. Token 统计
	if not delta.usage.is_empty():
		update_token_usage(delta.usage)


## 结束流式接收：刷出缓冲并将流式消息入库
func flush_stream_buffer() -> void:
	var has_live_block: bool = is_instance_valid(_streaming_block)
	
	if has_live_block:
		_streaming_block.finish_stream()
	
	var finished_msg: ChatMessage = _assembler.take()
	
	if finished_msg != null and chat_history != null:
		# 记录生成时的模型名：历史消息重绘时必须用它，而非实时的 current_model_name
		if not current_model_name.is_empty():
			finished_msg.metadata[ChatMessage.META_MODEL_NAME] = current_model_name
		
		# 仅当该消息确实被流式块实时渲染过，才标记跳过 message_added 的重复渲染。
		# 若流式块因重绘被释放且此后再无 chunk 触发重建，则必须让 message_added
		# 正常渲染，否则消息会入库成功却从 UI 上消失。
		if has_live_block:
			_stream_rendered_ids[finished_msg.get_instance_id()] = true
		
		chat_history.add_message(finished_msg)
	elif has_live_block:
		# 空响应：移除空 block
		_streaming_block.queue_free()
	
	_streaming_block = null


## 丢弃正在接收中的流式消息
## 既不落库，也不保留 UI 块。数据层面的回滚由 ChatMessageHistory.rollback_incomplete_turn() 负责。
func discard_streaming_message() -> void:
	_assembler.begin()
	
	if is_instance_valid(_streaming_block):
		_streaming_block.queue_free()
	_streaming_block = null
	
	_stream_rendered_ids.clear()


## 全量重绘消息列表
## 供外部在「流式数据被修正」或「数据层发生回滚」后调用；重绘期间重复调用会被合并。
func refresh_display() -> void:
	if _is_loading:
		_refresh_pending = true
		return
	
	_is_loading = true
	
	for child: Node in chat_list_container.get_children():
		child.queue_free()
	
	# 重绘释放了包括流式块在内的全部子节点，必须同步清空引用与待绑定标记：
	# 否则后续 handle_stream_chunk() 会对已释放节点调用 append_chunk()
	# （流式块本身会在下一个数据块到来时由 _ensure_streaming_block() 重建）
	_streaming_block = null
	_stream_rendered_ids.clear()
	
	await get_tree().process_frame
	
	if chat_history != null:
		for msg: ChatMessage in chat_history.messages:
			if msg.role == ChatMessage.ROLE_SYSTEM:
				continue
			_render_message(msg)
			await get_tree().process_frame
	
	_is_loading = false
	await get_tree().process_frame
	await get_tree().process_frame
	_scroll_to_bottom()
	_update_visibility_culling()
	
	if _refresh_pending:
		_refresh_pending = false
		refresh_display()


## 更新 Token 使用量并发出信号
func update_token_usage(p_usage: Dictionary) -> void:
	if not p_usage.is_empty():
		token_usage_updated.emit(p_usage)


# --- Private Functions ---

# 断开当前历史的数据信号绑定
func _unbind_history() -> void:
	if chat_history == null:
		return
	if chat_history.message_added.is_connected(_on_history_message_added):
		chat_history.message_added.disconnect(_on_history_message_added)
	if chat_history.turn_rolled_back.is_connected(refresh_display):
		chat_history.turn_rolled_back.disconnect(refresh_display)


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
	var model_name: String = ""
	if p_msg.role == ChatMessage.ROLE_ASSISTANT:
		model_name = String(p_msg.metadata.get(ChatMessage.META_MODEL_NAME, ""))
		# 兼容旧存档：无记录时回退到当前模型名
		if model_name.is_empty():
			model_name = current_model_name
	
	_add_block(p_msg.role, p_msg.content, p_msg.tool_calls, p_msg.images, p_msg.reasoning_content, model_name)


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
	var visible_top: float = scroll_offset - CULLING_BUFFER
	var visible_bottom: float = scroll_offset + viewport_height + CULLING_BUFFER
	
	# --- Debug 统计变量 ---
	var total_count: int = 0
	var suspended_count: int = 0
	var visible_count: int = 0
	# --------------------
	
	# 3. 遍历并切换状态
	for child: Node in chat_list_container.get_children():
		if child is ChatMessageBlock:
			var block: ChatMessageBlock = child
			total_count += 1 # 统计总数
			# VBoxContainer 中，子节点的 position.y 是相对于容器顶部的偏移
			var child_top: float = block.position.y
			var child_bottom: float = child_top + block.size.y
			
			# 判断是否与扩充后的视口相交
			# 如果 (子节点底部 < 视口顶部) 或 (子节点顶部 > 视口底部)，则完全在视口外
			if child_bottom < visible_top or child_top > visible_bottom:
				block.suspend_content()
				suspended_count += 1 # 统计挂起数
			else:
				block.resume_content()
				visible_count += 1 # 统计可见数
	
	# --- 打印 Debug 信息 ---
	# 只有当可见消息块较多时才打印，避免刷屏
	if visible_count > CULLING_DEBUG_THRESHOLD:
		AIChatLogger.debug("Debug: Total: %d | Visible: %d | Suspended: %d" % [total_count, visible_count, suspended_count])
	
	# [调试] 如果卡死依然发生，请观察控制台输出
	# 正常情况下，151个消息块，suspended_count 应该在 140 以上
	#print("Culling: Suspended %d / %d" % [suspended_count, chat_list_container.get_child_count()])


# 添加一个消息块到 UI
func _add_block(p_role: String, p_content: String, p_tool_calls: Array = [], p_images: Array = [], p_reasoning: String = "", p_model_name: String = "") -> void:
	var block: ChatMessageBlock = _create_block()
	block.set_content(p_role, p_content, p_model_name, p_tool_calls, p_reasoning)
	
	for img: Dictionary in p_images:
		if img.has("data"):
			block.display_image(img.data, img.get("mime", "image/png"))


# 实例化一个新的消息块
func _create_block() -> ChatMessageBlock:
	var block: ChatMessageBlock = CHAT_MESSAGE_BLOCK_SCENE.instantiate(PackedScene.GEN_EDIT_STATE_DISABLED)
	chat_list_container.add_child(block)
	return block


# 确保存在正在渲染的流式块；不存在则新建，并把装配器已累积的内容补渲染回去
# [为什么需要补渲染] refresh_display() 会释放包括流式块在内的全部子节点。
# 若重绘发生在流式进行中，新块必须从装配器的当前状态重建，
# 否则后续只会显示增量文本的尾部，与最终入库的完整消息不一致。
func _ensure_streaming_block() -> void:
	if is_instance_valid(_streaming_block):
		return
	
	_streaming_block = _create_block()
	_streaming_block.start_stream(ChatMessage.ROLE_ASSISTANT, current_model_name)
	
	var partial: ChatMessage = _assembler.get_message()
	if partial != null:
		if not partial.content.is_empty():
			_streaming_block.append_chunk(partial.content)
		if not partial.reasoning_content.is_empty():
			_streaming_block.append_reasoning(partial.reasoning_content)
		for tc: Dictionary in partial.tool_calls:
			_streaming_block.show_tool_call(tc)
	
	_scroll_to_bottom()


# 滚动到列表底部
func _scroll_to_bottom() -> void:
	_auto_scroll_enabled = true
	await get_tree().process_frame
	await get_tree().process_frame
	if chat_scroll_container.get_v_scroll_bar():
		chat_scroll_container.scroll_vertical = chat_scroll_container.get_v_scroll_bar().max_value


# 即时滚动到底部（layout 更新后执行）
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
	
	var sb: ScrollBar = chat_scroll_container.get_v_scroll_bar()
	if not sb:
		return
	
	if not sb.changed.is_connected(_on_scroll_bar_changed):
		sb.changed.connect(_on_scroll_bar_changed)
	if not sb.value_changed.is_connected(_on_scroll_value_changed):
		sb.value_changed.connect(_on_scroll_value_changed)
	
	_scroll_signals_connected = true


# --- Signal Callbacks ---

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
	var sb: ScrollBar = chat_scroll_container.get_v_scroll_bar()
	if sb and sb.max_value > 0:
		var max_scroll: float = sb.max_value - sb.page
		if p_value >= max_scroll - BOTTOM_THRESHOLD:
			_auto_scroll_enabled = true
		else:
			_auto_scroll_enabled = false
