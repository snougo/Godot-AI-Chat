@tool
class_name ContextBuilder
extends RefCounted

## 上下文构建器
##
## 负责构建发送给 AI 的上下文消息列表（System Prompt + History + Skills）。


# --- Public Functions ---

## 构建完整的上下文
static func build_context(p_history: ChatMessageHistory, p_settings: PluginSettingsConfig) -> Array[ChatMessage]:
	if not p_history or not p_settings:
		return []
	
	# 1. 基础 System Prompt
	var final_system_prompt: String = p_settings.system_prompt
	
	# 2. 注入工作区信息
	if not p_settings.workspace_path.is_empty():
		final_system_prompt += "\n\n===== WORKSPACE =====\n"
		final_system_prompt += "Current Workspace: `%s`\n" % p_settings.workspace_path
		final_system_prompt += "Use 'get_context' tool with context_type='folder_structure' to explore its structure.\n"
		final_system_prompt += "======================\n"
	
	# 3. 注入技能指令 (Skill Instructions)
	#var skill_instructions: String = ToolRegistry.get_combined_system_instructions()
	
	#if not skill_instructions.is_empty():
		#final_system_prompt += "\n\n===== SKILL INSTRUCTIONS =====\n"
		#final_system_prompt += "\n"
		#final_system_prompt += skill_instructions
		#final_system_prompt += "\n==================================\n"
	
	# 4. 截断历史记录并组合
	var context_messages: Array[ChatMessage] = p_history.get_truncated_messages(
		p_settings.max_chat_turns,
		final_system_prompt
	)
	
	return context_messages
