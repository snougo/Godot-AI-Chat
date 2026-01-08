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
var chat_message_block_scene: PackedScene = preload("res://addons/godot_ai_chat/scene/chat_message_block.tscn")

var current_model_name: String = ""


func load_history_resource(_history: ChatMessageHistory) -> void:
	chat_history = _history
	_refresh_display()


func append_user_message(_text: String) -> void:
	chat_history.add_user_message(_text)
	self._add_block(ChatMessage.ROLE_USER, _text, true)


func append_error_message(_text: String) -> void:
	var block: ChatMessageBlock = self._create_block()
	block.set_error(_text)
	self._scroll_to_bottom()


func append_tool_message(_tool_name: String, _result_text: String, _tool_call_id: String, _image_data: PackedByteArray = [], _image_mime: String = "") -> void:
	# 将图片数据也存入历史记录
	var msg := ChatMessage.new(ChatMessage.ROLE_TOOL, _result_text, _tool_name)
	msg.tool_call_id = _tool_call_id
	msg.image_data = _image_data
	msg.image_mime = _image_mime
	chat_history.add_message(msg)
	
	# UI 显示
	self._add_block(ChatMessage.ROLE_TOOL, _result_text, true, [], _image_data, _image_mime)
	self._scroll_to_bottom()


# [核心重构] 极简的流式处理
func handle_stream_chunk(_raw_chunk: Dictionary, _provider: BaseLLMProvider) -> void:
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
	var ui_update: Dictionary = _provider.process_stream_chunk(target_msg, _raw_chunk)
	
	# 3. 处理 UI 动画 (仅显示增量文本)
	var content_delta = ui_update.get("content_delta", "")
	var reasoning_delta = ui_update.get("reasoning_delta", "") # [新增]
	
	var last_block = self._get_last_block()
	var is_assistant_block: bool = (last_block != null and last_block.get_role() == ChatMessage.ROLE_ASSISTANT)
	
	if not (is_assistant_block and last_block.visible):
		var block: ChatMessageBlock = self._create_block()
		block.start_stream(ChatMessage.ROLE_ASSISTANT, current_model_name)
		last_block = block
	
	if not content_delta.is_empty():
		last_block.append_chunk(content_delta)
	
	# [新增] 处理思考内容增量
	if not reasoning_delta.is_empty():
		last_block.append_reasoning(reasoning_delta)
	
	# 4. 工具调用视觉反馈 (可选)
	if not target_msg.tool_calls.is_empty():
		for tc in target_msg.tool_calls:
			# 只要存在工具调用数据，就调用 Block 的显示方法
			# Block 内部会通过 ID 自动处理“创建”或“更新”
			last_block.show_tool_call(tc)
	
	# 5. Token 统计
	var usage = ui_update.get("usage", null)
	if usage is Dictionary and not usage.is_empty():
		update_token_usage(usage)
	
	self._scroll_to_bottom()


func commit_agent_history(_new_messages: Array[ChatMessage]) -> void:
	pass


func update_token_usage(_usage: Dictionary) -> void:
	if not _usage.is_empty():
		emit_signal("token_usage_updated", _usage)


func _refresh_display() -> void:
	for c in chat_list_container.get_children():
		c.queue_free()
	for msg in chat_history.messages:
		if msg.role == ChatMessage.ROLE_SYSTEM: continue
		# 传入图片数据参数
		# [修改] 传入 reasoning_content
		self._add_block(msg.role, msg.content, true, msg.tool_calls, msg.image_data, msg.image_mime, msg.reasoning_content)
	self._scroll_to_bottom()


# [修改] 增加 _reasoning 参数
func _add_block(_role: String, _content: String, _instant: bool, _tool_calls: Array = [], _image_data: PackedByteArray = [], _image_mime: String = "", _reasoning: String = "") -> void:
	var block: ChatMessageBlock = self._create_block()
	# [修改] 传递 _reasoning
	block.set_content(_role, _content, current_model_name if _role == ChatMessage.ROLE_ASSISTANT else "", _tool_calls, _reasoning)
	
	# 如果有图片数据，调用显示方法
	if not _image_data.is_empty():
		block.display_image(_image_data, _image_mime)
	
	self._scroll_to_bottom()


func _create_block() -> ChatMessageBlock:
	var block: ChatMessageBlock = chat_message_block_scene.instantiate()
	chat_list_container.add_child(block)
	return block


func _get_last_block() -> ChatMessageBlock:
	if chat_list_container.get_child_count() == 0:
		return null
	return chat_list_container.get_child(chat_list_container.get_child_count() - 1) as ChatMessageBlock


func _scroll_to_bottom() -> void:
	# 第一帧：RichTextLabel 根据文本内容计算自身大小
	# 第二帧：父容器响应子节点大小变化，更新 ScrollBar 的 max_value
	await get_tree().process_frame
	await get_tree().process_frame
	if chat_scroll_container.get_v_scroll_bar():
		chat_scroll_container.scroll_vertical = chat_scroll_container.get_v_scroll_bar().max_value
