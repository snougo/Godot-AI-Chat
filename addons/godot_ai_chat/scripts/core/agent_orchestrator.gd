@tool
class_name AgentOrchestrator
extends Node

## Agent 编排器
##
## 负责管理 AI 对话循环，处理工具调用链的执行。
## 本类不解析任何协议、不直接改写消息数据：
## 协议解析由 Provider 负责，数据落地由 StreamMessageAssembler 负责。


# --- Public Vars ---

var network_manager: NetworkManager
var current_chat_window: CurrentChatWindow
var chat_ui: ChatUI

## 当前工作流是否已被用户取消
var is_cancelled: bool = false


# --- Public Functions ---

## 取消当前工作流
func cancel_workflow() -> void:
	is_cancelled = true
	if network_manager:
		network_manager.cancel_stream()


## 运行聊天循环
## [param p_base_history]: 基础历史记录
## [param p_settings]: 插件设置
func run_chat_cycle(p_base_history: ChatMessageHistory, p_settings: PluginSettingsConfig) -> void:
	is_cancelled = false
	
	while true:
		if is_cancelled:
			break
		
		# 新一轮网络请求开始，确保状态切回等待响应
		if chat_ui:
			chat_ui.update_ui_state(ChatUI.UIState.WAITING_RESPONSE)
		
		# 使用 ContextBuilder 组装上下文
		var context: Array[ChatMessage] = ContextBuilder.build_context(p_base_history, p_settings)
		# 发起网络请求
		var response_result: Dictionary = await network_manager.request_chat_async(context)
		
		# 流式网络请求结束，立刻通知 UI 刷出缓冲区残留并停止打字机
		current_chat_window.flush_stream_buffer()
		
		if is_cancelled or not response_result.success:
			if not response_result.success and not is_cancelled:
				current_chat_window.append_error_message(String(response_result.error))
			break
		
		var last_msg: ChatMessage = p_base_history.get_last_message()
		if last_msg == null or last_msg.role != ChatMessage.ROLE_ASSISTANT:
			break
		
		if last_msg.tool_calls.is_empty():
			break
		
		var supports_inline: bool = network_manager.current_provider.supports_inline_tool_images()
		
		# 清洗工具调用：剔除伪调用（XML 包裹等），将被误判的文本抢救回 content
		var old_content_len: int = last_msg.content.length()
		ToolBox.salvage_and_clean_tool_calls(last_msg)
		
		# 如果发生了文本抢救，强制刷新 UI，把隐藏的文字显示出来
		if last_msg.content.length() > old_content_len:
			current_chat_window.refresh_display()
		
		# 如果清洗后发现全都是幻觉/误杀文本（空了），循环自然中止，等待用户的下一次输入
		if last_msg.tool_calls.is_empty():
			break
		
		# 存在有效工具调用，正式进入执行阶段，切换状态为 Executing Tools...
		if chat_ui:
			chat_ui.update_ui_state(ChatUI.UIState.TOOLCALLING)
		
		# 本轮工具返回的图片：先收集，等所有 tool 消息写完后统一注入。
		# 若在此处直接写入历史，会插进 tool 消息序列中间，破坏
		# 「tool_calls 之后必须紧跟同数量连续 tool 响应」的协议约束（400 格式错误）。
		var pending_images: Array[Dictionary] = []
		
		for raw_call: Variant in last_msg.tool_calls:
			if is_cancelled:
				break
			
			if not raw_call is Dictionary:
				continue
			
			var tc: Dictionary = raw_call
			# 此时数组里的工具一定是干净、合法且有 ID 的，直接使用
			var func_dict: Dictionary = tc.get("function", {})
			var tool_name: String = String(func_dict.get("name", ""))
			var raw_args: String = String(func_dict.get("arguments", "{}"))
			var call_id: String = String(tc.get("id", ""))
			
			var clean_args_str: String = JSONRepairHelper.repair_json(raw_args)
			func_dict["arguments"] = clean_args_str
			
			var args: Variant = JSON.parse_string(clean_args_str)
			if args == null:
				args = {}
			
			var tool_instance: AiTool = ToolRegistry.get_tool(tool_name)
			var result_str: String = ""
			var image_data: PackedByteArray = PackedByteArray()
			var image_mime: String = ""
			
			if tool_instance == null:
				result_str = "[SYSTEM ERROR] Tool '%s' not found." % tool_name
				AIChatLogger.error(result_str)
			else:
				var result: ToolResult = await tool_instance.execute(args)
				if is_cancelled:
					break
				
				result_str = result.get_data()
				
				if result.has_image():
					image_data = result.get_image_data()
					image_mime = result.get_image_mime()
					
					if not supports_inline and not image_data.is_empty():
						if result_str == "Image successfully read and attached to this message.":
							result_str = "Image content has been uploaded to the context as a new user message."
			
			current_chat_window.append_tool_message(
				tool_name,
				result_str,
				call_id,
				image_data if supports_inline else PackedByteArray(),
				image_mime if supports_inline else ""
			)
			
			# 不支持 inline 图片的 Provider：仅收集，写入历史推迟到循环之后
			if not supports_inline and not image_data.is_empty():
				pending_images.append({
					"data": image_data,
					"mime": image_mime,
					"tool_name": tool_name,
				})
		
		# 所有 tool 消息已就位，此时注入 User 消息才是合法位置
		if not pending_images.is_empty():
			var images: Array = []
			var tool_names: PackedStringArray = PackedStringArray()
			for img: Dictionary in pending_images:
				images.append({"data": img["data"], "mime": img["mime"]})
				tool_names.append(String(img["tool_name"]))
			current_chat_window.append_user_message(
				"Image content from tool(s): " + ", ".join(tool_names),
				images)
