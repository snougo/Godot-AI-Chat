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

# --- Public Vars ---

## 消息列表容器引用
var chat_list_container: VBoxContainer
## 滚动容器引用
var chat_scroll_container: ScrollContainer

## 当前加载的聊天历史资源
var chat_history: ChatMessageHistory
## 消息块场景
var chat_message_block_scene: PackedScene = preload("res://addons/godot_ai_chat/scene/chat_message_block.tscn")

## 当前使用的模型名称
var current_model_name: String = ""

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
## 现在支持递归回滚工具链，防止留下悬空的 Tool Output 或 Tool Call
func rollback_incomplete_message() -> void:
	if chat_history.messages.is_empty():
		return
	
	var safety_count: int = 0
	
	while not chat_history.messages.is_empty() and safety_count < 10:
		var last_msg: ChatMessage = chat_history.messages.back()
		var should_continue_rollback: bool = false
		
		# 1. 正在生成的纯文本 Assistant 消息 -> 删除并结束
		if last_msg.role == ChatMessage.ROLE_ASSISTANT and last_msg.tool_calls.is_empty():
			print("[CurrentChatWindow] Rolling back text message.")
			_pop_last_message_and_ui()
			break 
		
		# 2. 工具输出消息 (Tool) -> 删除，并继续检查上一条
		elif last_msg.role == ChatMessage.ROLE_TOOL:
			print("[CurrentChatWindow] Rolling back tool output.")
			_pop_last_message_and_ui()
			should_continue_rollback = true
		
		# 3. 包含工具调用的 Assistant 消息 -> 删除并结束 (这是这一轮的源头)
		elif last_msg.role == ChatMessage.ROLE_ASSISTANT and not last_msg.tool_calls.is_empty():
			print("[CurrentChatWindow] Rolling back tool call.")
			_pop_last_message_and_ui()
			break
		
		# 4. User 或 System -> 停止
		else:
			break
		
		if not should_continue_rollback:
			break
		
		safety_count += 1


## 提交 Agent 历史记录（占位符，逻辑已在 ChatHub 处理）
func commit_agent_history(_new_messages: Array[ChatMessage]) -> void:
	pass


## 更新 Token 使用量并发出信号
func update_token_usage(p_usage: Dictionary) -> void:
	if not p_usage.is_empty():
		token_usage_updated.emit(p_usage)


# --- Private Functions ---

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


## 辅助：移除最后一条数据和 UI
func _pop_last_message_and_ui() -> void:
	chat_history.messages.pop_back()
	var last_block: Node = _get_last_block()
	if last_block:
		last_block.queue_free()
