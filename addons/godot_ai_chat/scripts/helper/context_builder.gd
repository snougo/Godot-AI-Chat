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
		if p_settings.workspace_path != "res://":
			final_system_prompt += "\n\n===== WORKSPACE =====\n\n"
			final_system_prompt += "Current Workspace: `%s`\n\n" % p_settings.workspace_path
			final_system_prompt += "======================\n\n"
		else:
			final_system_prompt += "\n\nYou are in the Project Root `res://`"
	
	# 3. 注入当前时间
	var datetime_dict: Dictionary = Time.get_datetime_dict_from_system()
	final_system_prompt += "\n===== CURRENT TIME =====\n\n"
	final_system_prompt += "Current Time: %04d-%02d-%02d\n\n" % [datetime_dict.year, datetime_dict.month, datetime_dict.day]
	final_system_prompt += "========================\n\n"
	
	# 4. 注入记忆
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
			
			# --- 全局记忆：仅注入话题概览（话题名称 + 记忆数量） ---
			if not global_memories.is_empty():
				var topic_counts: Dictionary = {}
				var untopiced_count: int = 0
				for entry in global_memories:
					if not entry.topic.is_empty():
						if not topic_counts.has(entry.topic):
							topic_counts[entry.topic] = 0
						topic_counts[entry.topic] += 1
					else:
						untopiced_count += 1
				
				final_system_prompt += "\n\n===== GLOBAL MEMORIES =====\n"
				
				var topic_names: Array[String] = []
				for key in topic_counts.keys():
					topic_names.append(key)
				topic_names.sort()
				
				var display_items: Array[Dictionary] = []
				for topic_name in topic_names:
					display_items.append({"label": "Topic: %s" % topic_name, "count": topic_counts[topic_name]})
				if untopiced_count > 0:
					display_items.append({"label": "未分组", "count": untopiced_count})
				
				for i in display_items.size():
					final_system_prompt += "- **%s** (%d 条记忆)\n" % [display_items[i]["label"], display_items[i]["count"]]
					if i < display_items.size() - 1:
						final_system_prompt += "\n---\n\n"
				
				final_system_prompt += "==============================\n"
			
			# --- 工作区记忆：仅注入话题概览（话题名称 + 记忆数量） ---
			if not workspace_memories.is_empty():
				# 按 topic 统计数量
				var topic_counts: Dictionary = {}
				var untopiced_count: int = 0
				for entry in workspace_memories:
					if not entry.topic.is_empty():
						if not topic_counts.has(entry.topic):
							topic_counts[entry.topic] = 0
						topic_counts[entry.topic] += 1
					else:
						untopiced_count += 1
				
				final_system_prompt += "\n\n===== WORKSPACE MEMORIES =====\n"
				
				var topic_names: Array[String] = []
				for key in topic_counts.keys():
					topic_names.append(key)
				topic_names.sort()
				
				# 收集所有显示项
				var display_items: Array[Dictionary] = []
				for topic_name in topic_names:
					display_items.append({"label": "Topic: %s" % topic_name, "count": topic_counts[topic_name]})
				if untopiced_count > 0:
					display_items.append({"label": "未分组", "count": untopiced_count})
				
				# 逐项输出，项间用 --- 隔开（上下各留一空行）
				for i in display_items.size():
					final_system_prompt += "- **%s** (%d 条记忆)\n" % [display_items[i]["label"], display_items[i]["count"]]
					if i < display_items.size() - 1:
						final_system_prompt += "\n---\n\n"
				
				final_system_prompt += "==============================\n"
			
			#final_system_prompt += "\n"
			#final_system_prompt += "\n💡 > **Tip**: Use `search_memories` with a specific topic to retrieve the full content of memories under that topic.\n"
	
	# 5. 截断历史记录并组合
	var context_messages: Array[ChatMessage] = p_history.get_truncated_messages(
		p_settings.max_chat_turns,
		final_system_prompt
	)
	
	# Debug：输出完整系统提示词
	AIChatLogger.debug("=== System Prompt ===\n%s" % final_system_prompt, "ContextBuilder")
	
	return context_messages


# --- Private Functions ---

# 路径归一化：去除尾部斜杠
static func _normalize_path(p_path: String) -> String:
	return p_path.trim_suffix("/").trim_suffix("\\")
