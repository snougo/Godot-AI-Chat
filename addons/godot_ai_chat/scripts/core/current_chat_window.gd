@tool
extends Node
class_name CurrentChatWindow

# 定义 Token 更新信号
signal token_usage_updated(usage: Dictionary)

# --- 场景引用 ---
var chat_list_container: VBoxContainer
var chat_scroll_container: ScrollContainer

# --- 资源 ---
var chat_history: ChatMessageHistory
var chat_message_block_scene = preload("res://addons/godot_ai_chat/ui/chat_message_block.tscn")

var current_model_name: String = ""


func load_history_resource(history: ChatMessageHistory) -> void:
	chat_history = history
	_refresh_display()


func append_user_message(text: String) -> void:
	chat_history.add_user_message(text)
	_add_block(ChatMessage.ROLE_USER, text, true)


func append_error_message(text: String) -> void:
	var block = _create_block()
	block.set_error(text)
	_scroll_to_bottom()


# 增加 tool_call_id 参数
func append_tool_message(tool_name: String, result_text: String, tool_call_id: String) -> void:
	# 将正确的 ID 存入历史
	chat_history.add_tool_message(result_text, tool_call_id, tool_name)
	
	var block = _create_block()
	block.set_content(ChatMessage.ROLE_TOOL, result_text)
	_scroll_to_bottom()


# [核心重构] 极简的流式处理
func handle_stream_chunk(raw_chunk: Dictionary, provider: BaseLLMProvider) -> void:
	# 1. 确保数据层有 Assistant 消息
	var target_msg: ChatMessage = null
	if not chat_history.messages.is_empty():
		var last = chat_history.messages.back()
		if last.role == ChatMessage.ROLE_ASSISTANT:
			target_msg = last
	
	if target_msg == null:
		target_msg = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, "")
		chat_history.add_message(target_msg)
	
	# 2. [关键] 委托 Provider 处理所有脏活（拼装、合并、解析）
	var ui_update = provider.process_stream_chunk(target_msg, raw_chunk)
	
	# 3. 处理 UI 动画 (仅显示增量文本)
	var content_delta = ui_update.get("content_delta", "")
	
	var last_block = _get_last_block()
	var is_assistant_block = (last_block != null and last_block.get_role() == ChatMessage.ROLE_ASSISTANT)
	
	if not (is_assistant_block and last_block.visible):
		var block = _create_block()
		block.start_stream(ChatMessage.ROLE_ASSISTANT, current_model_name)
		last_block = block
	
	if not content_delta.is_empty():
		last_block.append_chunk(content_delta)
	
	# 4. 工具调用视觉反馈 (可选)
	if not target_msg.tool_calls.is_empty() and target_msg.content.strip_edges().is_empty():
		# 这里可以做一些显示 "Calling Tool..." 的逻辑，但为了防止重复显示，
		# 可以在 ChatMessageBlock 里加一个状态位，或者简单地跳过。
		pass
	
	# 5. Token 统计
	var usage = ui_update.get("usage", null)
	if usage is Dictionary and not usage.is_empty():
		update_token_usage(usage)
	
	_scroll_to_bottom()


func commit_agent_history(_new_messages: Array[ChatMessage]) -> void:
	pass


func update_token_usage(usage: Dictionary) -> void:
	if not usage.is_empty():
		emit_signal("token_usage_updated", usage)


func _refresh_display() -> void:
	for c in chat_list_container.get_children():
		c.queue_free()
	for msg in chat_history.messages:
		if msg.role == ChatMessage.ROLE_SYSTEM: continue
		_add_block(msg.role, msg.content, true)
	_scroll_to_bottom()


func _add_block(role: String, content: String, instant: bool) -> void:
	var block = _create_block()
	block.set_content(role, content, current_model_name if role == ChatMessage.ROLE_ASSISTANT else "")
	_scroll_to_bottom()


func _create_block() -> ChatMessageBlock:
	var block = chat_message_block_scene.instantiate()
	chat_list_container.add_child(block)
	return block


func _get_last_block() -> ChatMessageBlock:
	if chat_list_container.get_child_count() == 0: return null
	return chat_list_container.get_child(chat_list_container.get_child_count() - 1) as ChatMessageBlock


func _scroll_to_bottom() -> void:
	# 第一帧：RichTextLabel 根据文本内容计算自身大小
	# 第二帧：父容器响应子节点大小变化，更新 ScrollBar 的 max_value
	await get_tree().process_frame
	await get_tree().process_frame
	if chat_scroll_container.get_v_scroll_bar():
		chat_scroll_container.scroll_vertical = chat_scroll_container.get_v_scroll_bar().max_value
