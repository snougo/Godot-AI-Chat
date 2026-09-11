@tool
class_name ChatMessageHistory
extends Resource

## 聊天历史记录管理器
##
## 负责管理对话历史记录，提供增删改查及上下文截断功能。
## 所有对 messages 的修改都必须经由本类完成，视图层不得直接改写其内容。


# --- Signals ---

## 当一条新消息被追加到历史时发出（用于驱动视图增量渲染）
signal message_added(p_msg: ChatMessage)
## 当末尾未闭环的轮次被回滚（消息被删除）时发出，用于驱动视图全量重绘
signal turn_rolled_back


# --- Constants ---

## 回滚扫描上限：防御性护栏，避免异常数据导致死循环
const MAX_ROLLBACK_SCAN: int = 10


# --- @export Vars ---

## 核心数据存储：强类型的消息列表
@export var messages: Array[ChatMessage] = []
## 本会话累计的 Token 用量（随存档持久化）
## 结构: { "prompt": int, "completion": int, "total": int }
@export var token_usage: Dictionary = { "prompt": 0, "completion": 0, "total": 0 }


# --- Public Functions ---

## 添加一条消息到历史记录
func add_message(p_msg: ChatMessage) -> void:
	messages.append(p_msg)
	emit_changed()
	message_added.emit(p_msg)


## 添加一条用户消息
## [param p_content]: 消息内容
## [param p_images]: 可选的图片列表 [{"data": PackedByteArray, "mime": String}]
func add_user_message(p_content: String, p_images: Array = []) -> void:
	var msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_USER, p_content)
	
	# 处理多图
	for img: Dictionary in p_images:
		if img.has("data"):
			msg.add_image(img.data, img.get("mime", "image/png"))
	
	add_message(msg)


## 添加一条助手消息
func add_assistant_message(p_content: String, p_tool_calls: Array = []) -> void:
	var msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, p_content)
	msg.tool_calls = p_tool_calls
	add_message(msg)


## 添加一条工具执行结果消息
func add_tool_message(p_content: String, p_tool_call_id: String, p_tool_name: String) -> void:
	var msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_TOOL, p_content, p_tool_name)
	msg.tool_call_id = p_tool_call_id
	add_message(msg)


## 覆盖式写入本会话累计的 Token 用量
##
## [为什么用覆盖而非累加] 调用方传入的是「归档 + 当前请求」的完整快照，
## 覆盖语义天然幂等 —— 无论调用一次还是多次，结果都相同，不可能重复累加。
## 值未变化时不触发 emit_changed()，避免产生无谓的存档写入。
## [param p_usage]: 累计用量 { "prompt": int, "completion": int, "total": int }
func set_token_usage(p_usage: Dictionary) -> void:
	var prompt: int = int(p_usage.get("prompt", 0))
	var completion: int = int(p_usage.get("completion", 0))
	var total: int = int(p_usage.get("total", prompt + completion))
	
	if prompt == int(token_usage.get("prompt", 0)) \
			and completion == int(token_usage.get("completion", 0)) \
			and total == int(token_usage.get("total", 0)):
		return
	
	token_usage["prompt"] = prompt
	token_usage["completion"] = completion
	token_usage["total"] = total
	
	emit_changed()


## 清空所有历史记录
func clear() -> void:
	messages.clear()
	emit_changed()


## 获取最后一条消息
func get_last_message() -> ChatMessage:
	if messages.is_empty():
		return null
	return messages.back()


## 回滚末尾未闭环的轮次
##
## 「未闭环」指：末尾存在 Assistant 消息（无论是否附带工具调用），
## 其后的连续 Tool 消息都属于该次 Assistant 回复的产物。
## 本方法删除这些残留消息，使历史回到「最后一次用户输入之后」的干净状态。
##
## 这是数据层操作，视图刷新由 turn_rolled_back 信号驱动。
## [return]: 实际删除的消息条数
func rollback_incomplete_turn() -> int:
	var removed_count: int = 0
	var safety_count: int = 0
	
	# 纯数据回滚循环
	while not messages.is_empty() and safety_count < MAX_ROLLBACK_SCAN:
		var last_msg: ChatMessage = messages.back()
		
		# Tool 输出：删除并继续向上回滚
		if last_msg.role == ChatMessage.ROLE_TOOL:
			messages.pop_back()
			removed_count += 1
		# Assistant 消息（无论有无工具调用）：删除并停止
		elif last_msg.role == ChatMessage.ROLE_ASSISTANT:
			messages.pop_back()
			removed_count += 1
			break
		# User / System：停止
		else:
			break
		
		safety_count += 1
	
	if removed_count > 0:
		emit_changed()
		turn_rolled_back.emit()
	
	return removed_count


## 获取当前对话轮数
## 逻辑：获取结构化分组，且只统计那些“已完成闭环”（包含模型回复）的轮次
func get_turn_count() -> int:
	var turns: Array[Array] = _group_messages_into_turns()
	var valid_turns_count: int = 0
	
	for turn: Array in turns:
		# 检查该轮次是否包含 Assistant 或 Tool 消息
		var has_response: bool = false
		for msg: ChatMessage in turn:
			if msg.role == ChatMessage.ROLE_ASSISTANT or msg.role == ChatMessage.ROLE_TOOL:
				has_response = true
				break
		
		if has_response:
			valid_turns_count += 1
	
	return valid_turns_count


## 获取按轮次分组的消息列表（公开方法，供上下文压缩器使用）
## [return]: 每个元素为一轮消息的 ChatMessage 数组
func get_grouped_turns() -> Array[Array]:
	return _group_messages_into_turns()


## 截断历史记录（用于 Context Window 管理）
## [param p_max_turns]: 最大保留的对话轮数
## [param p_system_prompt]: 可选的系统提示词
## [param p_cleanup_pending_tool_calls]: 是否清理末尾悬挂的 Tool Call（Agent 流程中需设为 false）
## [return]: 截断后的 ChatMessage 数组
func get_truncated_messages(p_max_turns: int, p_system_prompt: String = "", p_cleanup_pending_tool_calls: bool = true) -> Array[ChatMessage]:
	# 1. 获取结构化的轮次列表
	var conversation_turns: Array[Array] = _group_messages_into_turns()
	
	# 2. 执行截断
	var truncated_turns: Array[Array] = conversation_turns
	if conversation_turns.size() > p_max_turns:
		truncated_turns = conversation_turns.slice(conversation_turns.size() - p_max_turns)
	
	# 3. 扁平化组装结果
	var result: Array[ChatMessage] = []
	
	# 3.1 插入 System Prompt (总是放在最前)
	if not p_system_prompt.is_empty():
		result.append(ChatMessage.new(ChatMessage.ROLE_SYSTEM, p_system_prompt))
	
	# 3.2 展开所有保留的轮次
	for turn: Array in truncated_turns:
		result.append_array(turn)
	
	# 仅在 p_cleanup_pending_tool_calls 为 true 时才执行清洗。
	# 防止在 Agent 连续对话中删除了刚刚生成的 Assistant 消息。
	if p_cleanup_pending_tool_calls:
		while not result.is_empty():
			var last: ChatMessage = result.back()
			if last.role == ChatMessage.ROLE_ASSISTANT and not last.tool_calls.is_empty():
				result.pop_back()
			else:
				break
	
	return result


# --- Private Functions ---

# 核心逻辑：将扁平消息列表按“轮”进行分组
# 规则 1: 一轮由 User 消息开始
# 规则 2: 连续的 User 消息会被合并到同一轮（视为补充或重试），直到出现 Assistant/Tool 消息
# 规则 3: 只有当一轮已经包含了 Assistant/Tool 消息后，新的 User 消息才会开启新的一轮
# 返回类型：每个元素为一轮消息的 ChatMessage 数组
func _group_messages_into_turns() -> Array[Array]:
	var turns: Array[Array] = []
	var current_turn: Array[ChatMessage] = []
	var current_turn_has_response: bool = false
	
	for msg: ChatMessage in messages:
		# System 消息独立于轮次之外处理
		if msg.role == ChatMessage.ROLE_SYSTEM:
			continue
		
		if msg.role == ChatMessage.ROLE_USER:
			# 关键判读：如果当前轮次已经有了回复，说明上一轮对话已闭环，User 开启新的一轮
			if current_turn_has_response:
				turns.append(current_turn)
				current_turn = []
				current_turn_has_response = false
			
			# 否则（当前轮次还没回复），这被视为连续的 User 输入（重试或补充），
			# 继续追加到当前轮次，不视为新轮次。
			current_turn.append(msg)
		
		else:
			# Assistant 或 Tool 消息，归属于当前轮
			# 如果没有 User 开头（current_turn 为空），则丢弃（孤立回复）
			if not current_turn.is_empty():
				current_turn.append(msg)
				# 标记当前轮次已收到回复
				current_turn_has_response = true
	
	# 处理最后一轮
	if not current_turn.is_empty():
		turns.append(current_turn)
	
	return turns
