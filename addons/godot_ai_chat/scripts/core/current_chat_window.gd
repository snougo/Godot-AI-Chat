@tool
extends Node
class_name CurrentChatWindow


# 当一条新的用户消息被成功添加到数据和UI后发出，通知网络层可以发送请求了。
signal new_user_message_append_completed(context_for_ai: Array)
# 当一条来自AI的流式消息完全接收并显示完毕后发出，通知UI可以恢复空闲状态。
signal new_assistant_message_append_completed(assistant_response: Dictionary)
# token消耗数据更新后通知UI
signal token_cost_updated(prompt_tokens: int, completion_tokens: int, total_tokens: int)

# 预加载聊天消息块场景，用于实例化
var chat_message_block: PackedScene = preload("res://addons/godot_ai_chat/ui/chat_message_block.tscn")

# 对聊天消息列表容器的引用
var chat_list_container: VBoxContainer
# 对聊天滚动容器的引用，用于自动滚动到底部
var chat_scroll_container: ScrollContainer
# 存储当前会话的所有消息（包括系统、用户、助手）
var chat_messages: Array = []
# 当前会话的系统提示词
var system_prompt: String = ""
# 当前选择的AI模型名称
var current_model_name: String = ""
# 在流式输出期间，保持对当前正在更新的 ChatMessageBlock 的引用
var current_chat_message_block: ChatMessageBlock = null
# token数据相关变量
var _total_prompt_tokens: int = 0
var _total_completion_tokens: int = 0
var _total_token_cost: int = 0


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 开始一个全新的聊天会话。
func creat_new_chat_window() -> void:
	_clear_chat_display() # 此函数会重置token
	chat_messages.clear()
	system_prompt = ToolBox.get_plugin_settings().system_prompt
	if not system_prompt.is_empty():
		# 注意：系统消息只存在于完整历史记录中，在发送给模型时会由 _get_truncated_chat_history 重新获取
		chat_messages.append({"role": "system", "content": system_prompt})


# 添加一条新的用户消息。
func append_new_user_message(_user_prompt: String) -> void:
	var user_message: Dictionary = {"role": "user", "content": _user_prompt}
	chat_messages.append(user_message)
	await _add_new_message_block_to_display(user_message)
	# 不再发送完整的历史记录，而是发送截断后的版本
	var context_for_ai: Array = _get_truncated_chat_history()
	ToolBox.print_structured_context("To AI Model (User Request)", context_for_ai)
	emit_signal("new_user_message_append_completed", context_for_ai)


# 加载一个聊天存档。
func load_chat_messages_from_archive(_chat_archive: Array) -> void:
	_clear_chat_display() # 此函数会重置token
	chat_messages = _chat_archive.duplicate(true)
	for message in chat_messages:
		if message.get("role") == "system":
			# 系统消息不直接显示
			continue
		else:
			var message_block: ChatMessageBlock = chat_message_block.instantiate()
			chat_list_container.add_child(message_block)
			await get_tree().process_frame
			
			# 调用我们新的、高度优化的异步加载函数
			# 这个函数内部会逐行处理内容并分帧执行，所以它会花费多帧时间
			await message_block.set_message_from_archive_async(message.get("role"), message.get("content"), current_model_name)
			await _scroll_to_bottom()


# 获取当前会话的所有消息数组。
func get_current_chat_messages() -> Array:
	return chat_messages


# 准备一个新的AI助手消息块。
func creat_new_assistant_message_block() -> void:
	# 在数据模型中创建一个空的助手消息占位
	var assistant_message: Dictionary = {"role": "assistant", "content": ""}
	chat_messages.append(assistant_message)
	
	# 在UI上创建一个对应的、初始不可见的 ChatMessageBlock
	var message_block: ChatMessageBlock = chat_message_block.instantiate()
	current_chat_message_block = message_block # 保持对当前块的引用
	chat_list_container.add_child(message_block)
	message_block.visible = false # 等待第一个token到达再显示
	
	# 初始化这个空块的标题等信息
	await get_tree().process_frame
	message_block.set_message_block("assistant", "", current_model_name)
	_scroll_to_bottom()


# 向当前正在流式输出的助手消息块中追加内容。
func append_chunk_to_assistant_message(text_chunk: String) -> void:
	if not is_instance_valid(current_chat_message_block):
		push_error("[CurrentChatWindow] append_chunk failed: current_chat_message_block is invalid!")
		return
	
	# 如果消息块当前是不可见的（即这是第一个token），则先让它显示出来
	if not current_chat_message_block.visible:
		current_chat_message_block.visible = true
	# 更新数据模型 (数组中的最后一条消息)
	chat_messages[-1]["content"] += text_chunk
	# 更新UI显示
	current_chat_message_block.append_chunk(text_chunk)
	# 持续滚动到底部，确保用户能看到新内容
	_scroll_to_bottom()


# 完成助手消息的流式输出：刷新UI并释放流式块引用
func complete_assistant_stream_output() -> void:
	# 用来处理所有在缓冲区中剩余的内容
	if is_instance_valid(current_chat_message_block):
		current_chat_message_block.flush_assistant_stream_output()
	# 清除对当前流式块的引用，表示本次流式输出结束
	current_chat_message_block = null
	# 关键修改：使用重构后的信号发出数据
	if not chat_messages.is_empty() and chat_messages[-1].role == "assistant":
		emit_signal("new_assistant_message_append_completed", chat_messages[-1])


# 提交AI模型消息的最终完整文本：更新数据模型并同步 UI
func commit_final_assistant_message(_final_message: Dictionary) -> void:
	# 覆盖数据模型
	if not chat_messages.is_empty() and chat_messages[-1].role == "assistant":
		chat_messages[-1] = _final_message
		# 同步UI
		var last_block = chat_list_container.get_child(chat_list_container.get_child_count() - 1)
		if is_instance_valid(last_block) and last_block is ChatMessageBlock:
			last_block.set_message_block(
				_final_message.role,
				_final_message.content,
				current_model_name
			)
	
	_scroll_to_bottom()


# 添加一个工具消息块到UI和数据模型
func add_tool_message_block(tool_message_dict: Dictionary) -> void:
	chat_messages.append(tool_message_dict)
	_add_tool_message_block_to_display_incrementally(tool_message_dict)


func add_token_usage(usage_data: Dictionary) -> void:
	var prompt_tokens_for_this_request: int = usage_data.get("prompt_tokens", 0)
	var completion_tokens_for_this_request: int = usage_data.get("completion_tokens", 0)
	
	# 直接、无条件地将每次独立API请求的消耗累加到总数上。
	# 这能正确处理来自初始请求和工具工作流后续请求的所有 token 数据。
	_total_prompt_tokens += prompt_tokens_for_this_request
	_total_completion_tokens += completion_tokens_for_this_request
	
	# --- 更新总计并发出信号 ---
	_total_token_cost = _total_prompt_tokens + _total_completion_tokens
	emit_signal("token_cost_updated", _total_prompt_tokens, _total_completion_tokens, _total_token_cost)


# 当流式传输中断时估算token消耗的累计值
func add_estimated_prompt_tokens(estimated_tokens: int) -> void:
	_total_prompt_tokens += estimated_tokens
	_total_token_cost = _total_prompt_tokens + _total_completion_tokens
	emit_signal("token_cost_updated", _total_prompt_tokens, _total_completion_tokens, _total_token_cost)


# 更新当前使用的模型名称。
func update_model_name(_model_name: String) -> void:
	current_model_name = _model_name


#==============================================================================
# ## 内部函数 ##
#==============================================================================

# 根据设置获取并截断聊天历史，用于发送给AI模型。
# 新逻辑：以“对话轮次”为单位进行截断。
func _get_truncated_chat_history() -> Array:
	# 1. 总是从ToolBox获取最新的设置
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	var max_turns: int = settings.max_chat_turns
	var system_prompt: String = settings.system_prompt
	
	# 2. 准备长期记忆的用户消息
	var long_term_memory_message: Dictionary = {}
	var remembered_folder_context: Dictionary = LongTermMemoryManager.get_all_folder_context()
	
	if not remembered_folder_context.is_empty():
		var memory_string: String = "The following is Long-Term Memory:\n\n---\n"
		for path in remembered_folder_context:
			var folder_tree = remembered_folder_context[path] # 直接使用字典中的纯净内容
			memory_string += "路径 `%s` 的文件夹结构:\n```\n%s\n```\n\n" % [path, folder_tree]
		
		long_term_memory_message = {"role": "user", "content": memory_string.strip_edges(), "is_memory": true}
	
	# 3. (原始逻辑) 处理和截断对话历史
	var conversation_turns: Array = []
	var current_turn: Array = []
	for message in chat_messages:
		if message.get("role") == "system": continue
		if message.get("role") == "user":
			if not current_turn.is_empty(): conversation_turns.append(current_turn)
			current_turn = [message]
		else:
			if not current_turn.is_empty(): current_turn.append(message)
	if not current_turn.is_empty(): conversation_turns.append(current_turn)
	
	var truncated_turns: Array = conversation_turns.slice(-max_turns) if conversation_turns.size() > max_turns else conversation_turns
	
	var final_messages: Array = []
	for turn in truncated_turns: final_messages.append_array(turn)
	
	# 4. 组装最终要发送给模型的历史记录
	var chat_messages_for_AI: Array = []
	
	# 4.1 放置主系统提示词
	if not system_prompt.is_empty():
		chat_messages_for_AI.append({"role": "system", "content": system_prompt})
	
	# 关键修复：将长期记忆放在对话历史的最前面，紧跟在系统提示词之后
	if not long_term_memory_message.is_empty():
		chat_messages_for_AI.append(long_term_memory_message)
	
	# 4.2 放置截断后的对话消息
	chat_messages_for_AI.append_array(final_messages)
	
	# 4.3 在用户最新消息前，插入长期记忆作为上下文
	#if not long_term_memory_message.is_empty():
		#var last_user_msg_index = -1
		#for i in range(chat_messages_for_AI.size() - 1, -1, -1):
			#if chat_messages_for_AI[i].role == "user":
				#last_user_msg_index = i
				#break
		#if last_user_msg_index != -1:
			#chat_messages_for_AI.insert(last_user_msg_index, long_term_memory_message)
		#else:
			#chat_messages_for_AI.append(long_term_memory_message)
	
	return chat_messages_for_AI


# 专门用于工具消息的函数，它会调用增量渲染方法。
func _add_tool_message_block_to_display_incrementally(_tool_message: Dictionary) -> void:
	var tool_message_block: ChatMessageBlock = chat_message_block.instantiate()
	tool_message_block.folded = true
	chat_list_container.add_child(tool_message_block)
	await get_tree().process_frame # 等待一帧确保节点准备就绪
	tool_message_block.set_tool_message_block(_tool_message.get("content"))
	_scroll_to_bottom()


# 实例化并添加一个新的消息块到显示区域。
# 此函数主要用于非流式消息（如用户消息和历史记录加载）。
func _add_new_message_block_to_display(message: Dictionary) -> void:
	var message_block: ChatMessageBlock = chat_message_block.instantiate()
	chat_list_container.add_child(message_block)
	# 等待一帧确保节点准备就绪
	await get_tree().process_frame
	# 调用我们新的、为即时显示优化的异步函数
	await message_block.set_message_block_context_async(message.get("role"), message.get("content"), current_model_name)
	await _scroll_to_bottom()


# 将聊天视图滚动到最底部。
func _scroll_to_bottom() -> void:
	await get_tree().process_frame # 等待UI更新完成
	if is_instance_valid(chat_scroll_container) and is_instance_valid(chat_scroll_container.get_v_scroll_bar()):
		chat_scroll_container.scroll_vertical = chat_scroll_container.get_v_scroll_bar().max_value


# 清空聊天显示区域的所有消息块。
func _clear_chat_display() -> void:
	current_chat_message_block = null # 确保在清空时也释放对流式块的引用
	_total_prompt_tokens = 0
	_total_completion_tokens = 0
	_total_token_cost = 0
	emit_signal("token_cost_updated", 0, 0, 0)
	for child in chat_list_container.get_children():
		child.queue_free()
