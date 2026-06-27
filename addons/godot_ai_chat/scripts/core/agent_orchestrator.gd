@tool
class_name AgentOrchestrator
extends Node

## Agent 编排器
##
## 负责管理 AI 对话循环，处理工具调用链的执行。

# --- Public Vars ---

var network_manager: NetworkManager
var current_chat_window: CurrentChatWindow
var chat_ui: ChatUI

var is_cancelled: bool = false


# --- Public Functions ---

## 取消当前工作流
func cancel_workflow() -> void:
	is_cancelled = true
	if network_manager:
		network_manager.cancel_stream()


## 运行聊天循环
## [param p_base_history]: 基础历史记录
##[param p_settings]: 插件设置
func run_chat_cycle(base_history: ChatMessageHistory, settings: PluginSettingsConfig) -> void:
	is_cancelled = false
	
	while true:
		if is_cancelled: break
		
		# 新一轮网络请求开始，确保状态切回等待响应
		if chat_ui:
			chat_ui.update_ui_state(ChatUI.UIState.WAITING_RESPONSE)
		
		# 使用 ContextBuilder 组装上下文
		var context: Array[ChatMessage] = ContextBuilder.build_context(base_history, settings)
		# 发起网络请求
		var response_result: Dictionary = await network_manager.request_chat_async(context)
		
		# 流式网络请求结束，立刻通知 UI 刷出缓冲区残留并停止打字机
		current_chat_window.flush_stream_buffer()
		
		if is_cancelled or not response_result.success:
			if not response_result.success and not is_cancelled:
				current_chat_window.append_error_message(response_result.error)
			break
		
		var last_msg: ChatMessage = base_history.get_last_message()
		if not last_msg or last_msg.role != ChatMessage.ROLE_ASSISTANT:
			break
		
		if last_msg.tool_calls.is_empty():
			break
		
		# 过滤 <think thinking> 标签里的幻觉工具调用
		var is_gemini: bool = (network_manager.current_provider is GeminiProvider)
		if not is_gemini and "<think thinking" in last_msg.content:
			last_msg.tool_calls = ToolBox.filter_hallucinated_tool_calls(last_msg.content, last_msg.tool_calls)
		
		# 清洗工具调用：剔除伪调用（XML 包裹等），将被误判的文本抢救回 content
		var old_content_len: int = last_msg.content.length()
		ToolBox.salvage_and_clean_tool_calls(last_msg, ToolRegistry.main_agent_tool)
		
		# 如果发生了文本抢救，强制刷新 UI，把隐藏的文字显示出来
		if last_msg.content.length() > old_content_len:
			if current_chat_window.has_method("_refresh_display"):
				current_chat_window._refresh_display()
		
		# 如果清洗后发现全都是幻觉/误杀文本（空了），循环自然中止，等待用户的下一次输入
		if last_msg.tool_calls.is_empty():
			break
		
		# 存在有效工具调用，正式进入执行阶段，切换状态为 Executing Tools...
		if chat_ui:
			chat_ui.update_ui_state(ChatUI.UIState.TOOLCALLING)
		
		for call in last_msg.tool_calls:
			if is_cancelled: break
			
			# 此时数组里的工具一定是干净、合法且有 ID 的，直接使用
			var tool_name: String = call.function.name
			var raw_args: String = call.function.get("arguments", "{}")
			var call_id: String = call.id
			
			var clean_args_str: String = JSONRepairHelper.repair_json(raw_args)
			if call.has("function"):
				call.function["arguments"] = clean_args_str
			
			var args: Variant = JSON.parse_string(clean_args_str)
			if args == null: args = {}
			
			var tool_instance: AiTool = ToolRegistry.get_tool(tool_name)
			var result_str: String = ""
			var image_data := PackedByteArray()
			var image_mime := ""
			
			if not tool_instance:
				result_str = "[SYSTEM ERROR] Tool '%s' not found." % tool_name
				AIChatLogger.error(result_str)
			else:
				var result: ToolResult = await _execute_tool_safely(tool_instance, args)
				if is_cancelled: break
				
				result_str = result.data
				
				if not result.attachments.is_empty() \
						and result.attachments.has("image_data") \
						and result.attachments.image_data is PackedByteArray \
						and not result.attachments.image_data.is_empty():
					image_data = result.attachments.image_data
					image_mime = result.attachments.get("mime", "image/png")
					
					if not is_gemini:
						if result_str == "Image successfully read and attached to this message.":
							result_str = "Image content has been uploaded to the context as a new user message."
			
			current_chat_window.append_tool_message(tool_name, result_str, call_id,
				image_data if is_gemini else PackedByteArray(),
				image_mime if is_gemini else "")
			
			# 将图片数据作为独立的 User 消息插入
			if not is_gemini and not image_data.is_empty():
				current_chat_window.append_user_message("Image content from tool: " + tool_name, [{"data": image_data, "mime": image_mime}])


# --- Private Functions ---

# 安全中间件：在执行工具前统一进行安全检查
# [param p_tool]: 工具实例
# [param p_args]: 工具参数
# [return]: ToolResult
func _execute_tool_safely(p_tool: AiTool, p_args: Dictionary) -> ToolResult:
	# READ_ONLY: 仅检查路径前缀和遍历，不检查黑名单
	if p_tool.security_level == AiTool.SecurityLevel.READ_ONLY:
		var path: String = p_args.get("path", "")
		if path.is_empty():
			path = p_args.get("scene_path", "")
		if not path.is_empty():
			if not path.begins_with("res://"):
				return ToolResult.fail("Path must start with 'res://'.")
			if ".." in path:
				return ToolResult.fail("Path traversal ('..') is not allowed.")
	
	# PATH_VALIDATED: 完整检查（前缀 + 遍历 + 黑名单）
	elif p_tool.security_level == AiTool.SecurityLevel.PATH_VALIDATED:
		var path: String = p_args.get("path", "")
		if path.is_empty():
			path = p_args.get("scene_path", "")
		if not path.is_empty():
			var err: String = p_tool.validate_path_safety(path)
			if not err.is_empty():
				return ToolResult.fail(err)
	
	# 兼容适配
	var raw_result: Variant = await p_tool.execute(p_args)
	if raw_result is ToolResult:
		return raw_result
	elif raw_result is Dictionary:
		return ToolResult.from_dict(raw_result)
	else:
		return ToolResult.fail("Tool returned unexpected type: %s" % typeof(raw_result))
