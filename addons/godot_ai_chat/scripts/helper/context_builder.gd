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
		final_system_prompt += "======================\n"
	
	# 3. 注入相关记忆（基于工作区召回）
	var memory_store_path: String = MemoryStore.SAVE_PATH
	if ResourceLoader.exists(memory_store_path):
		var store: MemoryStore = load(memory_store_path) as MemoryStore
		if store and not store.entries.is_empty() and not p_settings.workspace_path.is_empty():
			var relevant: Array[MemoryEntry] = store.get_relevant(p_settings.workspace_path, 5)
			if not relevant.is_empty():
				final_system_prompt += "\n\n===== RELEVANT MEMORIES =====\n"
				for entry in relevant:
					final_system_prompt += "- [%s][imp:%d/5] %s\n  %s\n" % [
						entry.memory_type,
						entry.importance,
						entry.title,
						entry.content
					]
				final_system_prompt += "==============================\n"
				store.save()  # 保存更新后的访问计数
	
	# 4. 截断历史记录并组合
	var context_messages: Array[ChatMessage] = p_history.get_truncated_messages(
		p_settings.max_chat_turns,
		final_system_prompt
	)
	
	return context_messages
