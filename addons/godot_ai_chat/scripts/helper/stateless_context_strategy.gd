@tool
class_name StatelessContextStrategy
extends ContextStrategy

## 无状态端点的上下文构建策略
##
## 适用于 OpenAI /v1/chat/completions、Anthropic /v1/messages 等无状态端点。
## 每次请求都需要发送完整的历史上下文。


func build_context(p_history: ChatMessageHistory, p_settings: PluginSettingsConfig, p_metadata: Dictionary = {}) -> Array[ChatMessage]:
	
	# 1. 组装 System Prompt
	var system_prompt: String = p_settings.system_prompt
	
	# 2. 注入技能指令
	var skill_instructions: String = ToolRegistry.get_combined_system_instructions()
	if not skill_instructions.is_empty():
		system_prompt += "\n\n===== SKILL INSTRUCTIONS =====\n"
		system_prompt += skill_instructions
		system_prompt += "\n==================================\n"
	
	# 3. 使用历史记录的截断方法获取完整上下文
	var max_turns: int = p_settings.max_chat_turns
	return p_history.get_truncated_messages(max_turns, system_prompt)
