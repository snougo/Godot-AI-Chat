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
				
				final_system_prompt += "\n===== GLOBAL MEMORIES =====\n"
				final_system_prompt += "Topic:\n"
				
				var topic_names: Array[String] = []
				for key in topic_counts.keys():
					topic_names.append(key)
				topic_names.sort()
				
				for topic_name in topic_names:
					final_system_prompt += "- **%s** (%d 条记忆)\n" % [topic_name, topic_counts[topic_name]]
				if untopiced_count > 0:
					final_system_prompt += "- **未分组** (%d 条记忆)\n" % untopiced_count
				
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
				final_system_prompt += "Topic:\n"
				
				var topic_names: Array[String] = []
				for key in topic_counts.keys():
					topic_names.append(key)
				topic_names.sort()
				
				for topic_name in topic_names:
					final_system_prompt += "- **%s** (%d 条记忆)\n" % [topic_name, topic_counts[topic_name]]
				if untopiced_count > 0:
					final_system_prompt += "- **未分组** (%d 条记忆)\n" % untopiced_count
				
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


## 构建 Sub-Agent 的上下文消息列表
## [param p_base_system_prompt]: SubAgentConfig.base_system_prompt
## [param p_skill_name]: 技能名称（用于加载对应的 SKILL.md）
## [param p_task_description]: 任务描述文本
## [return]: [SYSTEM, USER] 两条消息组成的数组
static func build_sub_agent_context(p_base_system_prompt: String, p_skill_name: String, p_task_description: String) -> Array[ChatMessage]:
	var messages: Array[ChatMessage] = []
	
	# 1. 加载技能指令（SKILL.md）
	var skill_instruction := ""
	var skill_res: Resource = ToolRegistry.available_skills.get(p_skill_name)
	if skill_res and "instruction_file" in skill_res:
		var path: String = skill_res.instruction_file
		if FileAccess.file_exists(path):
			skill_instruction = FileAccess.get_file_as_string(path)
	
	# 2. 组装 System Prompt
	var final_sys_prompt: String = p_base_system_prompt
	if not skill_instruction.is_empty():
		final_sys_prompt += "\n\n==== SKILL INSTRUCTION ====\n" + skill_instruction
	
	messages.append(ChatMessage.new(ChatMessage.ROLE_SYSTEM, final_sys_prompt))
	
	# 3. 组装 Task Prompt
	var final_user_prompt := "Please execute the following task using your tools:\n\n==== TASK DESCRIPTION ====\n" + p_task_description
	messages.append(ChatMessage.new(ChatMessage.ROLE_USER, final_user_prompt))
	
	return messages


# --- Private Functions ---

# 路径归一化：去除尾部斜杠
static func _normalize_path(p_path: String) -> String:
	return p_path.trim_suffix("/").trim_suffix("\\")
