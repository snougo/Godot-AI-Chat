@tool
class_name StreamMessageAssembler
extends RefCounted

## 流式消息装配器
##
## 持有「正在构建的助手消息」，把 LLMStreamDelta 落地到 ChatMessage。
## 它是「数据落地」的唯一入口：Provider 只产出协议无关增量，
## 视图只消费增量，双方都不需要理解对方的格式。


# --- Private Vars ---

# 正在装配的消息（null 表示尚未 begin 或已被 take）
var _message: ChatMessage = null

# 槽位稳定键 → _message.tool_calls 下标
var _slot_index_by_key: Dictionary = {}


# --- Public Functions ---

## 开始装配一条新的助手消息，清空上一次的流内状态
func begin() -> void:
	_message = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, "")
	_slot_index_by_key.clear()


## 当前正在装配的消息引用（可能为 null）
func get_message() -> ChatMessage:
	return _message


## 将一条增量落地到当前消息
## [param p_delta]: Provider 产出的协议无关增量
func apply(p_delta: LLMStreamDelta) -> void:
	if _message == null:
		begin()
	
	if not p_delta.content_delta.is_empty():
		_message.content += p_delta.content_delta
	
	if not p_delta.reasoning_delta.is_empty():
		_message.reasoning_content += p_delta.reasoning_delta
	
	for meta_key: Variant in p_delta.metadata_updates:
		_message.metadata[meta_key] = p_delta.metadata_updates[meta_key]
	
	for raw_delta: Dictionary in p_delta.tool_call_deltas:
		_apply_tool_call_delta(raw_delta)


## 是否存在可落库的装配结果
func has_content() -> bool:
	if _message == null:
		return false
	return (
		not _message.content.is_empty()
		or not _message.tool_calls.is_empty()
		or not _message.reasoning_content.is_empty()
	)


## 取出装配完成的消息并重置装配器
## [return]: 装配结果；无任何内容时返回 null
func take() -> ChatMessage:
	var result: ChatMessage = null
	if has_content():
		result = _message
	
	_message = null
	_slot_index_by_key.clear()
	return result


# --- Private Functions ---

# 将单条工具调用槽位增量落地到消息的 tool_calls 数组
func _apply_tool_call_delta(p_delta: Dictionary) -> void:
	var key: String = String(p_delta.get(LLMStreamDelta.FIELD_KEY, ""))
	if key.is_empty():
		return
	
	# 首次出现的键 → 追加一个新槽位（保持统一 tool_calls 结构，供各协议序列化器共用）
	if not _slot_index_by_key.has(key):
		_message.tool_calls.append({
			"id": "",
			"type": "function",
			"function": { "name": "", "arguments": "" },
		})
		_slot_index_by_key[key] = _message.tool_calls.size() - 1
	
	var slot_index: int = _slot_index_by_key[key]
	if slot_index >= _message.tool_calls.size():
		return
	
	var slot: Dictionary = _message.tool_calls[slot_index]
	var func_dict: Dictionary = slot.get("function", {})
	
	var new_id: String = String(p_delta.get(LLMStreamDelta.FIELD_ID, ""))
	if not new_id.is_empty():
		slot["id"] = new_id
	
	var name_fragment: String = String(p_delta.get(LLMStreamDelta.FIELD_NAME, ""))
	if not name_fragment.is_empty():
		func_dict["name"] = String(func_dict.get("name", "")) + name_fragment
	
	var arguments_fragment: String = String(p_delta.get(LLMStreamDelta.FIELD_ARGUMENTS, ""))
	if not arguments_fragment.is_empty():
		func_dict["arguments"] = String(func_dict.get("arguments", "")) + arguments_fragment
	
	var snapshot: String = String(p_delta.get(LLMStreamDelta.FIELD_ARGUMENTS_SNAPSHOT, ""))
	if not snapshot.is_empty():
		func_dict["arguments"] = snapshot
	
	slot["function"] = func_dict
