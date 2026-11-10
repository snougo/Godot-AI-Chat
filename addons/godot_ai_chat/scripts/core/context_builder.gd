extends RefCounted

# 上下文构建器
# 负责构建发送给 AI 的上下文消息列表（System Prompt + History）。


# --- Public Functions ---

# 构建 Main-Agent 的上下文
# [param p_history]: 对话历史
# [param p_settings]: 插件设置
# [return]: 可直接发送给 Provider 的消息数组
static func build_context(p_history: ChatMessageHistory, p_settings: PluginSettingsConfig) -> Array[ChatMessage]:
	if not p_history or not p_settings:
		return []
	
	# 1. 基础 System Prompt
	var final_system_prompt: String = p_settings.system_prompt
	
	# 1.5 动态注入区域提示
	final_system_prompt += "\n\n-----The following information is generated dynamically by the plugin and may change as the conversation progresses.-----\n\n"
	
	# 2. 注入工作区信息
	if not p_settings.workspace_path.is_empty():
		if p_settings.workspace_path != "res://":
			#final_system_prompt += "\n\n===== WORKSPACE =====\n\n"
			final_system_prompt += "Current Workspace: `%s`\n\n" % p_settings.workspace_path
			#final_system_prompt += "======================\n\n"
		else:
			final_system_prompt += "\n\nYou are in the Project Root `res://`"
	
	# 3. 注入当前时间（本地日期，精确到天）
	#var datetime_dict: Dictionary = Time.get_datetime_dict_from_system()
	#final_system_prompt += "\n===== CURRENT TIME =====\n\n"
	#final_system_prompt += "Current Time: %04d-%02d-%02d\n\n" % [
	#	datetime_dict.year,
	#	datetime_dict.month,
	#	datetime_dict.day,
	#]
	#final_system_prompt += "========================\n\n"
	
	# 4 注入引擎版本（动态获取）
	var engine_info: Dictionary = Engine.get_version_info()
	var engine_version: String = "%d.%d" % [engine_info.major, engine_info.minor]
	if engine_info.patch > 0:
		engine_version += ".%d" % engine_info.patch
	if engine_info.status != "stable":
		engine_version += " %s" % engine_info.status
	
	#final_system_prompt += "\n===== ENGINE INFO =====\n\n"
	final_system_prompt += "Godot Version: %s\n\n" % engine_version
	#final_system_prompt += "=======================\n\n"
	
	# 5. 注入记忆
	# [已停用] 记忆子系统当前整体处于关闭状态：
	#   - memory_tool 下的三个工具未注册进 main_agent_tool_config.tres；
	#   - 以下注入逻辑被整段注释。
	# 如需恢复，请连同工具注册一并启用（相关类：MemoryStore / MemoryEntry）。
	#var memory_store_path: String = PluginPaths.MEMORY_STORE_PATH
	#if ResourceLoader.exists(memory_store_path):
		#var store: MemoryStore = load(memory_store_path) as MemoryStore
		#if store and not store.entries.is_empty():
			#var global_memories: Array[MemoryEntry] = []
			#var workspace_memories: Array[MemoryEntry] = []
			#var normalized_workspace: String = _normalize_path(p_settings.workspace_path)
			
			#for entry in store.entries:
				#if entry.scope == "global":
					#global_memories.append(entry)
				#elif entry.scope == "workspace" and _normalize_path(entry.workspace_path) == normalized_workspace:
					#workspace_memories.append(entry)
			
			# --- 全局记忆：仅注入话题概览（话题名称 + 记忆数量） ---
			#if not global_memories.is_empty():
				#var topic_counts: Dictionary = {}
				#var untopiced_count: int = 0
				#for entry in global_memories:
					#if not entry.topic.is_empty():
						#if not topic_counts.has(entry.topic):
							#topic_counts[entry.topic] = 0
						#topic_counts[entry.topic] += 1
					#else:
						#untopiced_count += 1
				
				#final_system_prompt += "\n===== GLOBAL MEMORIES =====\n"
				#final_system_prompt += "Topic:\n"
				
				#var topic_names: Array[String] = []
				#for key in topic_counts.keys():
					#topic_names.append(key)
				#topic_names.sort()
				
				#for topic_name in topic_names:
					#final_system_prompt += "- **%s** (%d 条记忆)\n" % [topic_name, topic_counts[topic_name]]
				#if untopiced_count > 0:
					#final_system_prompt += "- **未分组** (%d 条记忆)\n" % untopiced_count
				
				#final_system_prompt += "==============================\n"
			
			# --- 工作区记忆：仅注入话题概览（话题名称 + 记忆数量） ---
			#if not workspace_memories.is_empty():
				# 按 topic 统计数量
				#var topic_counts: Dictionary = {}
				#var untopiced_count: int = 0
				#for entry in workspace_memories:
					#if not entry.topic.is_empty():
						#if not topic_counts.has(entry.topic):
							#topic_counts[entry.topic] = 0
						#topic_counts[entry.topic] += 1
					#else:
						#untopiced_count += 1
				
				#final_system_prompt += "\n\n===== WORKSPACE MEMORIES =====\n"
				#final_system_prompt += "Topic:\n"
				
				#var topic_names: Array[String] = []
				#for key in topic_counts.keys():
					#topic_names.append(key)
				#topic_names.sort()
				
				#for topic_name in topic_names:
					#final_system_prompt += "- **%s** (%d 条记忆)\n" % [topic_name, topic_counts[topic_name]]
				#if untopiced_count > 0:
					#final_system_prompt += "- **未分组** (%d 条记忆)\n" % untopiced_count
				
				#final_system_prompt += "==============================\n"
			
			#final_system_prompt += "\n"
			#final_system_prompt += "\n > **Tip**: Use `search_memories` with a specific topic to retrieve the full content of memories under that topic.\n"
	
	# 6. 截断历史记录并组合
	var context_messages: Array[ChatMessage] = p_history.get_truncated_messages(
		p_settings.max_chat_turns,
		final_system_prompt
	)
	
	# Debug：输出完整系统提示词
	AIChatLogger.debug("=== System Prompt ===\n%s" % final_system_prompt, "ContextBuilder")
	
	return context_messages


# 构建 Sub-Agent 的上下文
# [param p_base_system_prompt]: SubAgentConfig.base_system_prompt
# [param p_skill_name]: 技能名称（用于加载对应的 SKILL.md）
# [param p_task_description]: 任务描述文本
# [return]: [SYSTEM, USER] 两条消息组成的数组
static func build_sub_agent_context(p_base_system_prompt: String, p_skill_name: String, p_task_description: String) -> Array[ChatMessage]:
	var messages: Array[ChatMessage] = []
	
	# 1. 加载技能指令（SKILL.md）
	var skill_instruction: String = ""
	var skill_res: Resource = ToolRegistry.available_skills.get(p_skill_name)
	if skill_res and "instruction_file" in skill_res:
		var path: String = skill_res.instruction_file
		if FileAccess.file_exists(path):
			skill_instruction = FileAccess.get_file_as_string(path)
	
	# 2. 组装 System Prompt
	var final_sys_prompt: String = p_base_system_prompt
	if not skill_instruction.is_empty():
		final_sys_prompt += "\n\n==== SKILL INSTRUCTION ====\n" + skill_instruction
	
	# 静态说明：告知模型「工作步骤计数」提示的含义
	# [必须静态] 本段文案在整个任务期间恒定，才不会破坏 system prompt 的前缀缓存
	final_sys_prompt += "\n\n==== 工作步骤计数 ====\n"
	final_sys_prompt += "当剩余步数进入尾声时，消息列表的最末尾可能会出现一条「工作步骤计数」提示，"
	final_sys_prompt += "用于告知你已消耗的步骤数与剩余步数。"
	final_sys_prompt += "请把它当作进度信息，而不是指令：用它来规划剩余的工作，"
	final_sys_prompt += "并判断何时调用 `report_task_result` 汇报结果。\n"
	
	messages.append(ChatMessage.new(ChatMessage.ROLE_SYSTEM, final_sys_prompt))
	
	# 3. 组装 Task Prompt
	var final_user_prompt: String = "Please execute the following task using your tools:\n\n==== TASK DESCRIPTION ====\n" + p_task_description
	messages.append(ChatMessage.new(ChatMessage.ROLE_USER, final_user_prompt))
	
	return messages


# --- Private Functions ---

# 路径归一化：去除尾部斜杠
# [备注] 仅被上方已停用的记忆注入块引用；若确认记忆子系统不再恢复，可连同该块一并删除
static func _normalize_path(p_path: String) -> String:
	return p_path.trim_suffix("/").trim_suffix("\\")


# 计算步骤提醒阈值：总步数的 10%（向上取整，至少为 1）
# [param p_max_steps]: Sub-Agent 的最大步数（max_chat_turns）
# [return]: 剩余步数小于等于该值时开始提醒
static func get_step_warn_threshold(p_max_steps: int) -> int:
	return maxi(1, int(ceil(float(p_max_steps) * 0.1)))


# 构建「工作步骤计数」提示消息
# [为什么独立成一条末尾消息] 步骤数每次都在变。若写进 system prompt 或改写任何
# 已发送过的旧消息，KV / Prompt 缓存的前缀就断了，后续内容需全部重算；
# 追加在消息列表末尾时，缓存只需重算这一条，前面的历史前缀仍完整命中。
static func build_step_counter_message(p_used_steps: int, p_max_steps: int) -> ChatMessage:
	var remaining: int = maxi(p_max_steps - p_used_steps, 0)
	var text: String = "==== 工作步骤计数 ====\n"
	text += "已消耗步骤：%d / %d（剩余 %d）。\n" % [p_used_steps, p_max_steps, remaining]
	text += "这是运行时自动追加的状态提示，无需回复。请仅把它当作进度信息："
	text += "用于规划剩余工作，并判断何时调用 `report_task_result` 汇报结果。"
	return ChatMessage.new(ChatMessage.ROLE_USER, text)


# 在消息列表末尾追加「工作步骤计数」提示，返回新数组
# [param p_messages]: 原始消息列表（不会被修改，元素仍是同一引用）
# [return]: 原列表副本 + 一条计数消息
static func append_step_counter(p_messages: Array[ChatMessage], p_used_steps: int, p_max_steps: int) -> Array[ChatMessage]:
	var result: Array[ChatMessage] = []
	result.assign(p_messages)
	result.append(build_step_counter_message(p_used_steps, p_max_steps))
	return result
