@tool
class_name CurrentChatWindow
extends Node

## 负责管理当前聊天窗口的消息显示、流式处理以及 UI 滚动。

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
func load_history_resource(_history: ChatMessageHistory) -> void:
	chat_history = _history
	_refresh_display()


## 追加用户消息到历史和 UI
#func append_user_message(_text: String) -> void:
	#chat_history.add_user_message(_text)
	#_add_block(ChatMessage.ROLE_USER, _text, true)

func append_user_message(_text: String, _image_data: PackedByteArray = PackedByteArray(), _image_mime: String = "") -> void:
	chat_history.add_user_message(_text, _image_data, _image_mime)
	_add_block(ChatMessage.ROLE_USER, _text, true, [], _image_data, _image_mime)


## 追加错误消息到 UI
func append_error_message(_text: String) -> void:
	var _block: ChatMessageBlock = _create_block()
	_block.set_error(_text)
	_scroll_to_bottom()


## 追加工具消息到历史和 UI
func append_tool_message(_tool_name: String, _result_text: String, _tool_call_id: String, _image_data: PackedByteArray = PackedByteArray(), _image_mime: String = "") -> void:
	var _msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_TOOL, _result_text, _tool_name)
	_msg.tool_call_id = _tool_call_id
	_msg.image_data = _image_data
	_msg.image_mime = _image_mime
	chat_history.add_message(_msg)
	
	_add_block(ChatMessage.ROLE_TOOL, _result_text, true, [], _image_data, _image_mime)
	_scroll_to_bottom()


## 处理流式数据块
func handle_stream_chunk(_raw_chunk: Dictionary, _provider: BaseLLMProvider) -> void:
	# 1. 确保数据层有 Assistant 消息
	var _target_msg: ChatMessage = null
	if not chat_history.messages.is_empty():
		var _last: ChatMessage = chat_history.messages.back()
		if _last.role == ChatMessage.ROLE_ASSISTANT:
			_target_msg = _last
	
	if _target_msg == null:
		_target_msg = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, "")
		chat_history.add_message(_target_msg)
	
	# 2. 委托 Provider 处理拼装
	var _ui_update: Dictionary = _provider.process_stream_chunk(_target_msg, _raw_chunk)
	
	# 3. 处理 UI 动画
	var _content_delta: String = _ui_update.get("content_delta", "")
	var _reasoning_delta: String = _ui_update.get("reasoning_delta", "")
	
	var _last_block: ChatMessageBlock = _get_last_block()
	var _is_assistant_block: bool = (_last_block != null and _last_block.get_role() == ChatMessage.ROLE_ASSISTANT)
	
	if not (_is_assistant_block and _last_block.visible):
		var _block: ChatMessageBlock = _create_block()
		_block.start_stream(ChatMessage.ROLE_ASSISTANT, current_model_name)
		_last_block = _block
	
	if not _content_delta.is_empty():
		_last_block.append_chunk(_content_delta)
	
	if not _reasoning_delta.is_empty():
		_last_block.append_reasoning(_reasoning_delta)
	
	# 4. 工具调用视觉反馈
	if not _target_msg.tool_calls.is_empty():
		for _tc in _target_msg.tool_calls:
			_last_block.show_tool_call(_tc)
	
	# 5. Token 统计
	var _usage: Variant = _ui_update.get("usage", null)
	if _usage is Dictionary and not _usage.is_empty():
		update_token_usage(_usage)
	
	_scroll_to_bottom()


## 回滚未完成的消息（用于停止生成时）
## 现在支持递归回滚工具链，防止留下悬空的 Tool Output 或 Tool Call
func rollback_incomplete_message() -> void:
	if chat_history.messages.is_empty():
		return
	
	var _safety_count := 0
	
	while not chat_history.messages.is_empty() and _safety_count < 10:
		var _last_msg: ChatMessage = chat_history.messages.back()
		var _should_continue_rollback := false
		
		# 1. 正在生成的纯文本 Assistant 消息 -> 删除并结束
		if _last_msg.role == ChatMessage.ROLE_ASSISTANT and _last_msg.tool_calls.is_empty():
			print("[CurrentChatWindow] Rolling back text message.")
			_pop_last_message_and_ui()
			break 
		
		# 2. 工具输出消息 (Tool) -> 删除，并继续检查上一条
		elif _last_msg.role == ChatMessage.ROLE_TOOL:
			print("[CurrentChatWindow] Rolling back tool output.")
			_pop_last_message_and_ui()
			_should_continue_rollback = true
		
		# 3. 包含工具调用的 Assistant 消息 -> 删除并结束 (这是这一轮的源头)
		elif _last_msg.role == ChatMessage.ROLE_ASSISTANT and not _last_msg.tool_calls.is_empty():
			print("[CurrentChatWindow] Rolling back tool call.")
			_pop_last_message_and_ui()
			break
		
		# 4. User 或 System -> 停止
		else:
			break
		
		if not _should_continue_rollback:
			break
		
		_safety_count += 1


## 提交 Agent 历史记录（占位符，逻辑已在 ChatHub 处理）
func commit_agent_history(_new_messages: Array[ChatMessage]) -> void:
	pass


## 更新 Token 使用量并发出信号
func update_token_usage(_usage: Dictionary) -> void:
	if not _usage.is_empty():
		token_usage_updated.emit(_usage)


# --- Private Functions ---

## 刷新整个消息列表显示
func _refresh_display() -> void:
	for _c in chat_list_container.get_children():
		_c.queue_free()
	for _msg in chat_history.messages:
		if _msg.role == ChatMessage.ROLE_SYSTEM: 
			continue
		_add_block(_msg.role, _msg.content, true, _msg.tool_calls, _msg.image_data, _msg.image_mime, _msg.reasoning_content)
	_scroll_to_bottom()


## 添加一个消息块到 UI
func _add_block(_role: String, _content: String, _instant: bool, _tool_calls: Array = [], _image_data: PackedByteArray = PackedByteArray(), _image_mime: String = "", _reasoning: String = "") -> void:
	var _block: ChatMessageBlock = _create_block()
	_block.set_content(_role, _content, current_model_name if _role == ChatMessage.ROLE_ASSISTANT else "", _tool_calls, _reasoning)
	
	if not _image_data.is_empty():
		_block.display_image(_image_data, _image_mime)
	
	_scroll_to_bottom()


## 实例化一个新的消息块
func _create_block() -> ChatMessageBlock:
	var _block: ChatMessageBlock = chat_message_block_scene.instantiate()
	chat_list_container.add_child(_block)
	return _block


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
	var _last_block: Node = _get_last_block()
	if _last_block:
		_last_block.queue_free()
