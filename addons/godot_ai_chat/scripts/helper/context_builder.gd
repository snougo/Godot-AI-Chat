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
	
	# 3. 注入全局记忆（工作区记忆由模型通过 search_memories 工具按需检索）
	var memory_store_path: String = MemoryStore.SAVE_PATH
	if ResourceLoader.exists(memory_store_path):
		var store: MemoryStore = load(memory_store_path) as MemoryStore
		if store and not store.entries.is_empty():
			var global_memories: Array[MemoryEntry] = []
			for entry in store.entries:
				if entry.scope == "global":
					global_memories.append(entry)
			
			if not global_memories.is_empty():
				global_memories.sort_custom(func(a: MemoryEntry, b: MemoryEntry) -> bool:
					return a.importance > b.importance)
				
				final_system_prompt += "\n\n===== GLOBAL MEMORIES =====\n"
				for entry in global_memories:
					final_system_prompt += "- [%s][imp:%d/5] %s\n  %s\n" % [
						entry.memory_type,
						entry.importance,
						entry.title,
						entry.content
					]
				final_system_prompt += "==============================\n"
				store.save()
	
	# 4. 截断历史记录并组合
	var context_messages: Array[ChatMessage] = p_history.get_truncated_messages(
		p_settings.max_chat_turns,
		final_system_prompt
	)
	
	return context_messages
