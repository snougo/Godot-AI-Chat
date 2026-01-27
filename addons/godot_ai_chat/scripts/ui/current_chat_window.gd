@tool
class_name CurrentChatWindow
extends Node

## 当前聊天窗口逻辑控制器
##
## 负责管理当前聊天窗口的消息显示、流式处理以及 UI 滚动。
## 作为 UI 组件与数据层之间的中介，处理消息的追加、更新和回滚。

# --- Signals ---

## 当 Token 使用量更新时发出
signal token_usage_updated(usage: Dictionary)

# --- Constants ---
const CULLING_INTERVAL: float = 0.15 # 每秒检测约 6-7 次，足够平滑且低耗
## 消息块场景
const chat_message_block_scene: PackedScene = preload("res://addons/godot_ai_chat/scene/chat_message_block.tscn")

# --- Public Vars ---

## 消息列表容器引用
var chat_list_container: VBoxContainer
## 滚动容器引用
var chat_scroll_container: ScrollContainer
## 当前加载的聊天历史资源
var chat_history: ChatMessageHistory
## 当前使用的模型名称
var current_model_name: String = ""

# --- Private Vars ---

var _culling_timer: float = 0.0


# --- Built-in Functions ---

func _process(delta: float) -> void:
	_culling_timer += delta
	if _culling_timer >= CULLING_INTERVAL:
		_culling_timer = 0.0
		_update_visibility_culling()


# --- Public Functions ---

## 加载聊天历史资源并刷新显示
## [param p_history]: 聊天历史资源对象
func load_history_resource(p_history: ChatMessageHistory) -> void:
	chat_history = p_history
	_refresh_display()


## 追加用户消息到历史和 UI
## [param p_text]: 文本内容
## [param p_image_data]: 图片数据 (可选)
## [param p_image_mime]: 图片 MIME 类型 (可选)
func append_user_message(p_text: String, p_image_data: PackedByteArray = PackedByteArray(), p_image_mime: String = "") -> void:
	chat_history.add_user_message(p_text, p_image_data, p_image_mime)
	_add_block(ChatMessage.ROLE_USER, p_text, true, [], p_image_data, p_image_mime)


## 追加错误消息到 UI
## [param p_text]: 错误信息
func append_error_message(p_text: String) -> void:
	var block: ChatMessageBlock = _create_block()
	block.set_error(p_text)
	_scroll_to_bottom()


## 追加工具消息到历史和 UI
## [param p_tool_name]: 工具名称
## [param p_result_text]: 工具执行结果
## [param p_tool_call_id]: 工具调用 ID
## [param p_image_data]: 结果中的图片数据 (可选)
## [param p_image_mime]: 图片 MIME 类型 (可选)
func append_tool_message(p_tool_name: String, p_result_text: String, p_tool_call_id: String, p_image_data: PackedByteArray = PackedByteArray(), p_image_mime: String = "") -> void:
	var msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_TOOL, p_result_text, p_tool_name)
	msg.tool_call_id = p_tool_call_id
	msg.image_data = p_image_data
	msg.image_mime = p_image_mime
	chat_history.add_message(msg)
	
	_add_block(ChatMessage.ROLE_TOOL, p_result_text, true, [], p_image_data, p_image_mime)
	_scroll_to_bottom()


## 处理流式数据块
## [param p_raw_chunk]: 原始数据块
## [param p_provider]: LLM 提供者实例，用于解析数据块
func handle_stream_chunk(p_raw_chunk: Dictionary, p_provider: BaseLLMProvider) -> void:
	# 1. 确保数据层有 Assistant 消息
	var target_msg: ChatMessage = null
	if not chat_history.messages.is_empty():
		var last: ChatMessage = chat_history.messages.back()
		if last.role == ChatMessage.ROLE_ASSISTANT:
			target_msg = last
	
	if target_msg == null:
		target_msg = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, "")
		# [修复] 不要立即添加到历史记录，避免保存空内容消息
		#chat_history.add_message(target_msg)
	
	# 2. 委托 Provider 处理拼装
	var ui_update: Dictionary = p_provider.process_stream_chunk(target_msg, p_raw_chunk)
	
	# 3. 处理 UI 动画
	var content_delta: String = ui_update.get("content_delta", "")
	var reasoning_delta: String = ui_update.get("reasoning_delta", "")
	
	var last_block: ChatMessageBlock = _get_last_block()
	var is_assistant_block: bool = (last_block != null and last_block.get_role() == ChatMessage.ROLE_ASSISTANT)
	
	if not (is_assistant_block and last_block.visible):
		var block: ChatMessageBlock = _create_block()
		block.start_stream(ChatMessage.ROLE_ASSISTANT, current_model_name)
		last_block = block
	
	if not content_delta.is_empty():
		last_block.append_chunk(content_delta)
	
	if not reasoning_delta.is_empty():
		last_block.append_reasoning(reasoning_delta)
	
	# 4. 工具调用视觉反馈
	if not target_msg.tool_calls.is_empty():
		for tc in target_msg.tool_calls:
			last_block.show_tool_call(tc)
	
	# 5. Token 统计
	var usage: Variant = ui_update.get("usage", null)
	if usage is Dictionary and not usage.is_empty():
		update_token_usage(usage)
	
	_scroll_to_bottom()
	
	# [辅助] 如果消息有实际内容，确保它被添加到历史记录
	# 注意：这是辅助机制，主要修复在 ChatBackend 中
	if not chat_history.messages.is_empty():
		var last: ChatMessage = chat_history.messages.back()
		if last.role != ChatMessage.ROLE_ASSISTANT:
			# 如果最后一条不是 Assistant 消息，且当前消息有内容，则添加
			if not target_msg.content.is_empty() or not target_msg.tool_calls.is_empty():
				chat_history.add_message(target_msg)


## 回滚未完成的消息（用于停止生成时）
## [Refactor] 采用数据优先策略：先清理 history，再根据 history 重绘 UI
func rollback_incomplete_message() -> void:
	# 即使历史为空，也可能存在游离的 UI 块（例如第一条消息生成时停止），所以仍需刷新
	if chat_history.messages.is_empty():
		_refresh_display()
		return
	
	var safety_count: int = 0
	
	# 1. 纯数据回滚循环
	while not chat_history.messages.is_empty() and safety_count < 10:
		var last_msg: ChatMessage = chat_history.messages.back()
		var should_continue_rollback: bool = false
		var should_pop: bool = false
		
		# 情况 A: 正在生成的纯文本 Assistant 消息 -> 删除并结束
		if last_msg.role == ChatMessage.ROLE_ASSISTANT and last_msg.tool_calls.is_empty():
			AIChatLogger.debug("[CurrentChatWindow] Rolling back text message in history.")
			should_pop = true
			should_continue_rollback = false 
		
		# 情况 B: 工具输出消息 (Tool) -> 删除，并继续检查上一条
		elif last_msg.role == ChatMessage.ROLE_TOOL:
			AIChatLogger.debug("[CurrentChatWindow] Rolling back tool output in history.")
			should_pop = true
			should_continue_rollback = true
		
		# 情况 C: 包含工具调用的 Assistant 消息 -> 删除并结束 (这是这一轮的源头)
		elif last_msg.role == ChatMessage.ROLE_ASSISTANT and not last_msg.tool_calls.is_empty():
			AIChatLogger.debug("[CurrentChatWindow] Rolling back tool call in history.")
			should_pop = true
			should_continue_rollback = false
		
		# 情况 D: User 或 System -> 停止
		else:
			break
		
		if should_pop:
			chat_history.messages.pop_back()
		
		if not should_continue_rollback:
			break
		
		safety_count += 1
	
	# 2. 强制重绘 UI
	# 这会消除所有“游离”的、未入库的 UI Block，保证视图与数据绝对一致
	_refresh_display()


## 提交 Agent 历史记录（占位符，逻辑已在 ChatHub 处理）
func commit_agent_history(_new_messages: Array[ChatMessage]) -> void:
	pass


## 更新 Token 使用量并发出信号
func update_token_usage(p_usage: Dictionary) -> void:
	if not p_usage.is_empty():
		token_usage_updated.emit(p_usage)


# --- Private Functions ---

## 执行可视性剔除逻辑
func _update_visibility_culling() -> void:
	if not is_instance_valid(chat_scroll_container) or not is_instance_valid(chat_list_container):
		return
	
	# 1. 获取视口范围
	# scroll_vertical 代表可视区域顶部的偏移量
	var scroll_offset: float = chat_scroll_container.scroll_vertical
	var viewport_height: float = chat_scroll_container.size.y
	
	# 2. 设置缓冲区 (Buffer)
	# 上下各预留 600 像素，确保快速滚动时不会看到空白
	var buffer: float = 100.0
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
	if visible_count > 8:
		AIChatLogger.debug("Debug: Total: %d | Visible: %d | Suspended: %d" % [total_count, visible_count, suspended_count])


## 刷新整个消息列表显示
func _refresh_display() -> void:
	for c in chat_list_container.get_children():
		c.queue_free()
	
	for msg in chat_history.messages:
		if msg.role == ChatMessage.ROLE_SYSTEM: 
			continue
		_add_block(msg.role, msg.content, true, msg.tool_calls, msg.image_data, msg.image_mime, msg.reasoning_content)
	
	_scroll_to_bottom()


## 添加一个消息块到 UI
func _add_block(p_role: String, p_content: String, p_instant: bool, p_tool_calls: Array = [], p_image_data: PackedByteArray = PackedByteArray(), p_image_mime: String = "", p_reasoning: String = "") -> void:
	var block: ChatMessageBlock = _create_block()
	block.set_content(p_role, p_content, current_model_name if p_role == ChatMessage.ROLE_ASSISTANT else "", p_tool_calls, p_reasoning)
	
	if not p_image_data.is_empty():
		block.display_image(p_image_data, p_image_mime)
	
	_scroll_to_bottom()


## 实例化一个新的消息块
func _create_block() -> ChatMessageBlock:
	var block: ChatMessageBlock = chat_message_block_scene.instantiate()
	chat_list_container.add_child(block)
	return block


## 获取列表中的最后一个消息块
func _get_last_block() -> ChatMessageBlock:
	if chat_list_container.get_child_count() == 0:
		return null
	return chat_list_container.get_child(chat_list_container.get_child_count() - 1) as ChatMessageBlock


## 滚动到列表底部
func _scroll_to_bottom() -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	if chat_scroll_container.get_v_scroll_bar():
		chat_scroll_container.scroll_vertical = chat_scroll_container.get_v_scroll_bar().max_value
