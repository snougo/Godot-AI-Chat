@tool
class_name ChatMessageHistory
extends Resource

## 负责管理对话历史记录，提供增删改查及上下文截断功能。

# --- @export Vars ---

## 核心数据存储：强类型的消息列表
@export var messages: Array[ChatMessage] = []

# --- Public Functions ---

## 添加一条消息到历史记录
func add_message(_msg: ChatMessage) -> void:
	messages.append(_msg)
	emit_changed()


## 添加一条用户消息
func add_user_message(_content: String) -> void:
	add_message(ChatMessage.new(ChatMessage.ROLE_USER, _content))


## 添加一条助手消息
func add_assistant_message(_content: String, _tool_calls: Array = []) -> void:
	var _msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, _content)
	_msg.tool_calls = _tool_calls
	add_message(_msg)


## 添加一条工具执行结果消息
func add_tool_message(_content: String, _tool_call_id: String, _tool_name: String) -> void:
	var _msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_TOOL, _content, _tool_name)
	_msg.tool_call_id = _tool_call_id
	add_message(_msg)


## 清空所有历史记录
func clear() -> void:
	messages.clear()
	emit_changed()


## 获取最后一条消息
func get_last_message() -> ChatMessage:
	if messages.is_empty():
		return null
	return messages.back()


## 截断历史记录（用于 Context Window 管理）
## [param _max_turns]: 最大保留的对话轮数
## [param _system_prompt]: 可选的系统提示词
## [return]: 截断后的 ChatMessage 数组
func get_truncated_messages(_max_turns: int, _system_prompt: String = "") -> Array[ChatMessage]:
	var _conversation_turns: Array[Array] = []
	var _current_turn: Array[ChatMessage] = []
	
	for _msg in messages:
		if _msg.role == ChatMessage.ROLE_SYSTEM: 
			continue
		
		if _msg.role == ChatMessage.ROLE_USER:
			if not _current_turn.is_empty():
				_conversation_turns.append(_current_turn)
			_current_turn = [_msg]
		else:
			if not _current_turn.is_empty():
				_current_turn.append(_msg)
	
	if not _current_turn.is_empty():
		_conversation_turns.append(_current_turn)
	
	# 截断
	var _truncated_turns: Array[Array] = _conversation_turns
	if _conversation_turns.size() > _max_turns:
		_truncated_turns = _conversation_turns.slice(_conversation_turns.size() - _max_turns)
	
	# 组装结果
	var _result: Array[ChatMessage] = []
	
	# 1. 插入 System Prompt
	if not _system_prompt.is_empty():
		_result.append(ChatMessage.new(ChatMessage.ROLE_SYSTEM, _system_prompt))
	
	# 2. 插入对话
	for _turn in _truncated_turns:
		_result.append_array(_turn)
	
	return _result
