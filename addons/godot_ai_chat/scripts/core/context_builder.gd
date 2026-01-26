@tool
class_name ContextBuilder
extends RefCounted

## 上下文构建器
##
## 负责构建发送给 AI 的上下文消息列表（System Prompt + History + Skills）。

# --- Public Functions ---

# 构建完整的上下文
# [param p_history]: 原始聊天记录资源
# [param p_settings]: 插件设置
# [return]: 准备发送给 API 的 ChatMessage 数组
static func build_context(p_history: ChatMessageHistory, p_settings: PluginSettings) -> Array[ChatMessage]:
	if not p_history or not p_settings:
		return []

	# 1. 基础 System Prompt
	var final_system_prompt: String = p_settings.system_prompt
	
	# 2. 注入技能指令 (Skill Instructions)
	# ToolRegistry 是全局静态类，直接调用
	var skill_instructions: String = ToolRegistry.get_combined_system_instructions()
	
	if not skill_instructions.is_empty():
		final_system_prompt += "\n\n=== MOUNTED SKILL INSTRUCTIONS ===\n"
		final_system_prompt += "The following specialized skills have been mounted to your capability set. Use them when appropriate.\n"
		final_system_prompt += skill_instructions
		final_system_prompt += "\n==================================\n"
		final_system_prompt += "IMPERATIVE: You must strictly follow the guidelines above in your response."
	
	# 3. 截断历史记录并组合
	# ChatMessageHistory.get_truncated_messages 已经包含了把 System Prompt 放在第一位的逻辑
	var context_messages: Array[ChatMessage] = p_history.get_truncated_messages(
		p_settings.max_chat_turns,
		final_system_prompt
	)
	
	return context_messages
