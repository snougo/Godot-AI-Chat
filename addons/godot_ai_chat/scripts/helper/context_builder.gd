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
	
	# 3. 注入记忆（全局记忆全部 + 当前工作区 session_summary 前5条）
	var memory_store_path: String = MemoryStore.SAVE_PATH
	if ResourceLoader.exists(memory_store_path):
		var store: MemoryStore = load(memory_store_path) as MemoryStore
		if store and not store.entries.is_empty():
			var global_memories: Array[MemoryEntry] = []
			var workspace_memories: Array[MemoryEntry] = []
			var normalized_workspace: String = _normalize_path(p_settings.workspace_path)
			
			for entry in store.entries:
				if entry.scope == "global":
					global_memories.append(entry)
				elif entry.scope == "workspace" and _normalize_path(entry.workspace_path) == normalized_workspace:
					workspace_memories.append(entry)
			
			# --- 全局记忆：全部注入，按创建时间降序 ---
			if not global_memories.is_empty():
				global_memories.sort_custom(func(a: MemoryEntry, b: MemoryEntry) -> bool:
					return a.created_at > b.created_at)
				
				final_system_prompt += "\n\n===== GLOBAL MEMORIES =====\n"
				for entry in global_memories:
					final_system_prompt += "- [%s] %s\n  %s\n" % [
						entry.memory_type,
						entry.title,
						entry.content
					]
				final_system_prompt += "==============================\n"
			
			# --- 工作区记忆：只筛选 session_summary，取最新10条 ---
			if not workspace_memories.is_empty():
				var session_summaries: Array[MemoryEntry] = []
				for entry in workspace_memories:
					if entry.memory_type == "session_summary":
						session_summaries.append(entry)
				
				if not session_summaries.is_empty():
					session_summaries.sort_custom(
						func(a: MemoryEntry, b: MemoryEntry) -> bool:
							# 主排序：创建时间降序（最新优先）
							if a.created_at != b.created_at:
								return a.created_at > b.created_at
							# 次排序：session_summary 优先（保留结构，虽已全是此类型）
							var a_priority: int = 0 if a.memory_type == "session_summary" else 1
							var b_priority: int = 0 if b.memory_type == "session_summary" else 1
							return a_priority < b_priority
							)
					
					if session_summaries.size() > 5:
						session_summaries = session_summaries.slice(0, 5)
					
					final_system_prompt += "\n\n===== WORKSPACE MEMORIES =====\n"
					for entry in session_summaries:
						final_system_prompt += "- [%s] %s (%s)\n  %s\n" % [
							entry.memory_type,
							entry.title,
							entry.created_at.replace("T", " "),
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


# --- Private Functions ---

# 路径归一化：去除尾部斜杠
static func _normalize_path(p_path: String) -> String:
	return p_path.trim_suffix("/").trim_suffix("\\")
