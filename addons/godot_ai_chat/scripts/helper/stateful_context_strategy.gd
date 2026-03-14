@tool
class_name StatefulContextStrategy
extends ContextStrategy

## 有状态端点的上下文构建策略
##
## 适用于 LM Studio /v1/responses、OpenAI /v1/responses 等有状态端点。
## 首次请求发送完整上下文，后续请求仅发送最新输入。


func build_context(p_history: ChatMessageHistory, p_settings: PluginSettingsConfig, p_metadata: Dictionary = {}) -> Array[ChatMessage]:
	
	var is_first_request: bool = p_metadata.get("is_first_request", true)
	var result: Array[ChatMessage] = []
	
	if is_first_request:
		# === 首次请求：需要完整上下文 ===
		result = _build_first_request_context(p_history, p_settings)
	else:
		# === 后续请求：仅发送最新输入 ===
		result = _build_follow_up_context(p_history)
	
	return result


## 构建首次请求的上下文
func _build_first_request_context(p_history: ChatMessageHistory, p_settings: PluginSettingsConfig) -> Array[ChatMessage]:
	
	var result: Array[ChatMessage] = []
	
	# 1. 组装 System Prompt
	var system_prompt: String = p_settings.system_prompt
	var skill_instructions: String = ToolRegistry.get_combined_system_instructions()
	
	if not skill_instructions.is_empty():
		system_prompt += "\n\n===== SKILL INSTRUCTIONS =====\n"
		system_prompt += skill_instructions
		system_prompt += "\n==================================\n"
	
	# 2. 添加 System 消息
	if not system_prompt.is_empty():
		result.append(ChatMessage.new(ChatMessage.ROLE_SYSTEM, system_prompt))
	
	# 3. 对于首次请求，找到当前轮次的用户消息
	# （只发送用户输入，不包含历史，因为服务器还没有状态）
	var last_msg: ChatMessage = p_history.get_last_message()
	if last_msg and last_msg.role == ChatMessage.ROLE_USER:
		result.append(last_msg)
	
	return result


## 构建后续请求的上下文（仅最新输入）
func _build_follow_up_context(p_history: ChatMessageHistory) -> Array[ChatMessage]:
	
	var result: Array[ChatMessage] = []
	var last_msg: ChatMessage = p_history.get_last_message()
	
	if not last_msg:
		return result
	
	# 只发送最后一条消息（用户新输入或工具结果）
	result.append(last_msg)
	
	return result
