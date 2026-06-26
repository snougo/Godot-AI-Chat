@tool
class_name ContextCompressor
extends RefCounted

## 上下文压缩器
##
## 当对话轮次超过设定阈值时，将旧对话送 LLM 进行摘要压缩。
## 保留第一轮原始对话 + 摘要内容，构造新的对话历史资源。


# --- Public Functions ---

## 执行上下文压缩
## [param p_history]: 原始对话历史
## [param p_network_manager]: 网络管理器（用于发送非流式摘要请求）
## [param p_config]: 压缩配置
## [return]: {"success": bool, "error": String, "new_history": ChatMessageHistory}
func compress_context(p_history: ChatMessageHistory, p_network_manager: NetworkManager, p_config: ContextCompressionConfig) -> Dictionary:
	if not p_history or not p_network_manager or not p_config:
		return {"success": false, "error": "Invalid parameters."}
	
	# 1. 获取分组轮次
	var turns: Array = p_history.get_grouped_turns()
	
	if turns.size() < 2:
		return {"success": false, "error": "Not enough turns to compress (need at least 2)."}
	
	# 2. 保留第一轮，格式化剩余轮次
	var first_turn: Array = turns[0]
	var conversation_text: String = _format_turns_for_summary(turns.slice(1))
	
	AIChatLogger.info("[ContextCompressor] Compressing %d turns into summary..." % (turns.size() - 1), "ContextCompressor")
	
	# 3. 构建摘要请求消息
	var summary_messages: Array[ChatMessage] = []
	summary_messages.append(ChatMessage.new(ChatMessage.ROLE_SYSTEM, p_config.summary_prompt))
	
	var user_prompt := "Please summarize the following conversation:\n\n---\n" + conversation_text + "\n---\n"
	summary_messages.append(ChatMessage.new(ChatMessage.ROLE_USER, user_prompt))
	
	# 4. 发送非流式摘要请求
	var result: Dictionary = await p_network_manager.request_non_stream_async(summary_messages, p_config)
	
	if not result.success:
		return {"success": false, "error": result.error}
	
	var summary_content: String = result.content.strip_edges()
	if summary_content.is_empty():
		return {"success": false, "error": "Summary content is empty."}
	
	AIChatLogger.info("[ContextCompressor] Summary received (%d chars)." % summary_content.length(), "ContextCompressor")
	
	# 5. 构造新的对话历史
	var new_history := ChatMessageHistory.new()
	
	# 5.1 深拷贝第一轮消息（确保新会话与旧会话数据独立）
	for msg in first_turn:
		var msg_copy := msg.duplicate(true) as ChatMessage
		if msg_copy:
			new_history.add_message(msg_copy)
		else:
			new_history.add_message(msg)
	
	# 5.2 添加摘要作为 User 消息
	var summary_wrapper := "📎 **[Previous Conversation Summary]**\n\n" + summary_content
	new_history.add_user_message(summary_wrapper)
	
	return {"success": true, "new_history": new_history}


# --- Private Functions ---

## 将轮次数组格式化为可读文本（用于摘要请求的输入）
static func _format_turns_for_summary(p_turns: Array) -> String:
	var lines: Array[String] = []
	
	for i in range(p_turns.size()):
		var turn: Array = p_turns[i]
		lines.append("--- Turn %d ---" % (i + 2))
		
		for msg in turn:
			if msg.role == ChatMessage.ROLE_SYSTEM:
				continue
			
			var role_label: String = ""
			match msg.role:
				ChatMessage.ROLE_USER:
					role_label = "User"
				ChatMessage.ROLE_ASSISTANT:
					role_label = "Assistant"
				ChatMessage.ROLE_TOOL:
					role_label = "Tool(%s)" % msg.name
				_:
					role_label = msg.role
			
			if msg.role == ChatMessage.ROLE_ASSISTANT and not msg.tool_calls.is_empty():
				if not msg.content.is_empty():
					lines.append("[%s]: %s" % [role_label, msg.content])
				for tc in msg.tool_calls:
					var func_name: String = tc.get("function", {}).get("name", "unknown")
					var args: String = tc.get("function", {}).get("arguments", "{}")
					if args.length() > 500:
						args = args.substr(0, 500) + "..."
					lines.append("  → Called tool: %s(%s)" % [func_name, args])
			elif msg.role == ChatMessage.ROLE_TOOL:
				var tool_content: String = msg.content
				if tool_content.length() > 2000:
					tool_content = tool_content.substr(0, 2000) + "\n... (truncated)"
				lines.append("[%s]: %s" % [role_label, tool_content])
			else:
				# ↓↓↓ 新增：检测上一轮摘要并添加显式标注 ↓↓↓
				var content_text: String = msg.content
				if content_text.contains("📎") and content_text.contains("[Previous Conversation Summary]"):
					lines.append("[%s]: ⚠️ [THIS IS A PREVIOUS SUMMARY — its contents MUST be fully incorporated into the new summary, do NOT discard] %s" % [role_label, content_text])
				else:
					lines.append("[%s]: %s" % [role_label, content_text])
		
		lines.append("")
	
	return "\n".join(lines)
