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

# --- Private Vars ---

var _is_cancelled: bool = false


# --- Public Functions ---

## 取消当前工作流
func cancel_workflow() -> void:
	_is_cancelled = true
	if network_manager:
		network_manager.cancel_stream()


## 运行聊天循环
## [param p_base_history]: 基础历史记录
##[param p_settings]: 插件设置
func run_chat_cycle(base_history: ChatMessageHistory, settings: PluginSettingsConfig) -> void:
	_is_cancelled = false
	
	while true:
		if _is_cancelled: break
		
		# 新一轮网络请求开始，确保状态切回等待响应
		if chat_ui:
			chat_ui.update_ui_state(ChatUI.UIState.WAITING_RESPONSE)
		
		# 使用 ContextBuilder 组装上下文
		var context: Array[ChatMessage] = ContextBuilder.build_context(base_history, settings)
		# 发起网络请求
		var response_result: Dictionary = await network_manager.request_chat_async(context)
		
		# 流式网络请求结束，立刻通知 UI 刷出缓冲区残留并停止打字机
		current_chat_window.flush_stream_buffer()
		
		if _is_cancelled or not response_result.success:
			if not response_result.success and not _is_cancelled:
				current_chat_window.append_error_message(response_result.error)
			break
		
		var last_msg: ChatMessage = base_history.get_last_message()
		if not last_msg or last_msg.role != ChatMessage.ROLE_ASSISTANT:
			break
		
		if last_msg.tool_calls.is_empty():
			break
		
		# 过滤 <think> 标签里的幻觉工具调用
		var is_gemini: bool = (network_manager.current_provider is GeminiProvider)
		if not is_gemini and "<think>" in last_msg.content:
			last_msg.tool_calls = ToolBox.filter_hallucinated_tool_calls(last_msg.content, last_msg.tool_calls)
		
		#[终极修复]: 抢救被服务端误拦截的合法文本，并清洗真正的工具调用
		var old_content_len: int = last_msg.content.length()
		ToolBox.salvage_and_clean_tool_calls(last_msg)
		
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
			if _is_cancelled: break
			
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
				var result_dict: Dictionary = await tool_instance.execute(args)
				if _is_cancelled: break
				
				var data_val: Variant = result_dict.get("data", "")
				if data_val is Dictionary or data_val is Array:
					result_str = JSON.stringify(data_val, "\t")
				else:
					result_str = str(data_val)
				
				if result_dict.has("attachments"):
					var att: Dictionary = result_dict.attachments
					if att.has("image_data"):
						image_data = att.image_data
						image_mime = att.get("mime", "image/png")
						
						if not is_gemini and not image_data.is_empty():
							_attach_image_to_last_user_message(base_history, image_data, image_mime)
							if result_str == "Image successfully read and attached to this message.":
								result_str = "Image content has been uploaded to the context. Please check the user message."
							image_data = PackedByteArray()
			
			current_chat_window.append_tool_message(tool_name, result_str, call_id, image_data, image_mime)


# --- Private Functions ---

# 附加图片到最后一条用户消息
func _attach_image_to_last_user_message(history: ChatMessageHistory, p_data: PackedByteArray, p_mime: String) -> void:
	for i in range(history.messages.size() - 1, -1, -1):
		if history.messages[i].role == ChatMessage.ROLE_USER:
			history.messages[i].add_image(p_data, p_mime)
			return
