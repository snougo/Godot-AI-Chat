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
	
	# 3. 注入记忆
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
			
			# --- 工作区记忆：按 topic 分组，每个 topic 取最新2条 ---
			if not workspace_memories.is_empty():
				# 按创建时间降序排序（最新在前）
				workspace_memories.sort_custom(func(a: MemoryEntry, b: MemoryEntry) -> bool:
					return a.created_at > b.created_at)
				
				# 按 topic 分组
				var grouped: Dictionary = {}
				var untopiced: Array[MemoryEntry] = []
				for entry in workspace_memories:
					if not entry.topic.is_empty():
						if not grouped.has(entry.topic):
							grouped[entry.topic] = []
						grouped[entry.topic].append(entry)
					else:
						untopiced.append(entry)
				
				# 每个 topic 只取最新2条
				for topic_name in grouped.keys():
					if grouped[topic_name].size() > 2:
						grouped[topic_name] = grouped[topic_name].slice(0, 2)
				
				final_system_prompt += "\n\n===== WORKSPACE MEMORIES =====\n"
				
				var topic_names: Array[String] = []
				for key in grouped.keys():
					topic_names.append(key)
				topic_names.sort()
				
				for topic_name in topic_names:
					final_system_prompt += "\n--- Topic: %s ---\n" % topic_name
					for entry in grouped[topic_name]:
						final_system_prompt += "- [%s] %s (%s)\n  %s\n" % [
							entry.memory_type,
							entry.title,
							entry.created_at.replace("T", " "),
							entry.content
						]
				
				if not untopiced.is_empty():
					final_system_prompt += "\n--- 未分组 ---\n"
					for entry in untopiced:
						final_system_prompt += "- [%s] %s (%s)\n  %s\n" % [
							entry.memory_type,
							entry.title,
							entry.created_at.replace("T", " "),
							entry.content
						]
				
				final_system_prompt += "\n💡 Tip: Use search_memories with a specific topic to retrieve all memories under that topic.\n"
				
				final_system_prompt += "==============================\n"
	
	# 4. 截断历史记录并组合
	var context_messages: Array[ChatMessage] = p_history.get_truncated_messages(
		p_settings.max_chat_turns,
		final_system_prompt
	)
	
	# 5. Debug：输出完整系统提示词
	AIChatLogger.debug("=== System Prompt ===\n%s" % final_system_prompt, "ContextBuilder")
	
	return context_messages


# --- Private Functions ---

# 路径归一化：去除尾部斜杠
static func _normalize_path(p_path: String) -> String:
	return p_path.trim_suffix("/").trim_suffix("\\")
