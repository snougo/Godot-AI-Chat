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
#func add_user_message(_content: String) -> void:
	#add_message(ChatMessage.new(ChatMessage.ROLE_USER, _content))

func add_user_message(_content: String, _image_data: PackedByteArray = PackedByteArray(), _image_mime: String = "") -> void:
	var _msg = ChatMessage.new(ChatMessage.ROLE_USER, _content)
	_msg.image_data = _image_data
	_msg.image_mime = _image_mime
	add_message(_msg)


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


## 获取当前对话轮数
## 逻辑：获取结构化分组，且只统计那些“已完成闭环”（包含模型回复）的轮次
func get_turn_count() -> int:
	var _turns: Array = _group_messages_into_turns()
	var _valid_turns_count: int = 0
	
	for _turn in _turns:
		# 检查该轮次是否包含 Assistant 或 Tool 消息
		var _has_response: bool = false
		for _msg in _turn:
			if _msg.role == ChatMessage.ROLE_ASSISTANT or _msg.role == ChatMessage.ROLE_TOOL:
				_has_response = true
				break
		
		if _has_response:
			_valid_turns_count += 1
			
	return _valid_turns_count


## 截断历史记录（用于 Context Window 管理）
## [param _max_turns]: 最大保留的对话轮数
## [param _system_prompt]: 可选的系统提示词
## [return]: 截断后的 ChatMessage 数组
## [param _cleanup_pending_tool_calls]: 新增参数，默认 true。但在 Agent 工作流中需设为 false。
func get_truncated_messages(_max_turns: int, _system_prompt: String = "", _cleanup_pending_tool_calls: bool = true) -> Array[ChatMessage]:
	# 1. 获取结构化的轮次列表
	var _conversation_turns: Array = _group_messages_into_turns()
	
	# 2. 执行截断
	var _truncated_turns: Array = _conversation_turns
	if _conversation_turns.size() > _max_turns:
		_truncated_turns = _conversation_turns.slice(_conversation_turns.size() - _max_turns)
	
	# 3. 扁平化组装结果
	var _result: Array[ChatMessage] = []
	
	# 3.1 插入 System Prompt (总是放在最前)
	if not _system_prompt.is_empty():
		_result.append(ChatMessage.new(ChatMessage.ROLE_SYSTEM, _system_prompt))
	
	# 3.2 展开所有保留的轮次
	for _turn in _truncated_turns:
		_result.append_array(_turn)
	
	# [修复] 仅在 _cleanup_pending_tool_calls 为 true 时才执行清洗。
	# 防止在 Agent 连续对话中删除了刚刚生成的 Assistant 消息。
	if _cleanup_pending_tool_calls:
		while not _result.is_empty():
			var _last: ChatMessage = _result.back()
			if _last.role == ChatMessage.ROLE_ASSISTANT and not _last.tool_calls.is_empty():
				_result.pop_back()
			else:
				break
	
	return _result

# --- Private Functions ---

## 核心逻辑：将扁平消息列表按“轮”进行分组
## 规则 1: 一轮由 User 消息开始
## 规则 2: 连续的 User 消息会被合并到同一轮（视为补充或重试），直到出现 Assistant/Tool 消息
## 规则 3: 只有当一轮已经包含了 Assistant/Tool 消息后，新的 User 消息才会开启新的一轮
## 返回类型：Array[Array[ChatMessage]]
func _group_messages_into_turns() -> Array:
	var _turns: Array = []
	var _current_turn: Array[ChatMessage] = []
	var _current_turn_has_response: bool = false
	
	for _msg in messages:
		# System 消息独立于轮次之外处理
		if _msg.role == ChatMessage.ROLE_SYSTEM: 
			continue
		
		if _msg.role == ChatMessage.ROLE_USER:
			# 关键判读：如果当前轮次已经有了回复，说明上一轮对话已闭环，User 开启新的一轮
			if _current_turn_has_response:
				_turns.append(_current_turn)
				_current_turn = []
				_current_turn_has_response = false
			
			# 否则（当前轮次还没回复），这被视为连续的 User 输入（重试或补充），
			# 继续追加到当前轮次，不视为新轮次。
			_current_turn.append(_msg)
			
		else:
			# Assistant 或 Tool 消息，归属于当前轮
			# 如果没有 User 开头（_current_turn 为空），则丢弃（孤立回复）
			if not _current_turn.is_empty():
				_current_turn.append(_msg)
				# 标记当前轮次已收到回复
				_current_turn_has_response = true
	
	# 处理最后一轮
	if not _current_turn.is_empty():
		_turns.append(_current_turn)
	
	return _turns
