@tool
extends Resource
class_name ChatMessageHistory

# 核心数据存储：强类型的消息列表
@export var messages: Array[ChatMessage] = []


# --- 增删改查基础操作 ---

func add_message(msg: ChatMessage) -> void:
	messages.append(msg)
	emit_changed() # 通知资源已更改，Godot 会标记需要保存


func add_user_message(content: String) -> void:
	add_message(ChatMessage.new(ChatMessage.ROLE_USER, content))


func add_assistant_message(content: String, tool_calls: Array = []) -> void:
	var msg = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, content)
	msg.tool_calls = tool_calls
	add_message(msg)


func add_tool_message(content: String, tool_call_id: String, tool_name: String) -> void:
	var msg = ChatMessage.new(ChatMessage.ROLE_TOOL, content, tool_name)
	msg.tool_call_id = tool_call_id
	add_message(msg)


func clear() -> void:
	messages.clear()
	emit_changed()


func get_last_message() -> ChatMessage:
	if messages.is_empty():
		return null
	return messages.back()


# --- 核心逻辑：上下文构建 ---

# 截断历史记录（用于 Context Window 管理）
# 返回强类型的 ChatMessage 数组
func get_truncated_messages(max_turns: int, system_prompt: String = "") -> Array[ChatMessage]:
	var conversation_turns: Array[Array] = []
	var current_turn: Array[ChatMessage] = []
	
	for msg in messages:
		if msg.role == ChatMessage.ROLE_SYSTEM: continue
		
		if msg.role == ChatMessage.ROLE_USER:
			if not current_turn.is_empty():
				conversation_turns.append(current_turn)
			current_turn = [msg]
		else:
			if not current_turn.is_empty():
				current_turn.append(msg)
	
	if not current_turn.is_empty():
		conversation_turns.append(current_turn)
	
	# 截断
	var truncated_turns = conversation_turns
	if conversation_turns.size() > max_turns:
		truncated_turns = conversation_turns.slice(conversation_turns.size() - max_turns)
	
	# 组装结果
	var result: Array[ChatMessage] = []
	
	# 1. 插入 System Prompt
	if not system_prompt.is_empty():
		# 创建临时的 System 消息对象 (不需要存入历史，只用于发送)
		result.append(ChatMessage.new(ChatMessage.ROLE_SYSTEM, system_prompt))
	
	# 2. 插入对话
	for turn in truncated_turns:
		result.append_array(turn)
	
	return result
