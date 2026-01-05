@tool
extends RefCounted
class_name ToolWorkflowManager

signal completed(final_msg: ChatMessage, history: Array[ChatMessage])
signal failed(error: String)
signal tool_msg_generated(msg: ChatMessage)

var network_manager: NetworkManager
var tool_executor: ToolExecutor
var base_history: Array[ChatMessage] # 初始历史
var workflow_messages: Array[ChatMessage] = [] # 本次 workflow 产生的新消息

# 临时状态
var temp_assistant_msg: ChatMessage


func _init(nm: NetworkManager, te: ToolExecutor, history: Array[ChatMessage]):
	network_manager = nm
	tool_executor = te
	base_history = history


func cleanup() -> void:
	# 断开所有网络信号
	if network_manager.new_stream_chunk_received.is_connected(_on_chunk):
		network_manager.new_stream_chunk_received.disconnect(_on_chunk)
	if network_manager.chat_stream_request_completed.is_connected(_on_stream_done):
		network_manager.chat_stream_request_completed.disconnect(_on_stream_done)


func start(trigger_msg: ChatMessage) -> void:
	# 触发消息已经存在于 base_history 中 (由外部保证) 或者在这里加入
	# 这里假设 trigger_msg 是这一轮的起点，且尚未加入 workflow_messages
	# 但通常 trigger_msg 已经在 UI 上显示并进入了 base_history。
	# 我们主要关注它里面的 tool_calls。
	
	_execute_tool_calls(trigger_msg)


func _execute_tool_calls(msg: ChatMessage) -> void:
	# 遍历执行所有工具
	for call in msg.tool_calls:
		var call_id = call.get("id", "")
		var func_def = call.get("function", {})
		var tool_name = func_def.get("name", "")
		var args_str = func_def.get("arguments", "{}")
		
		# [优化] 在控制台打印，方便调试，同时为后续 UI 状态扩展预留位置
		print("[Workflow] Executing tool: %s" % tool_name)
		
		# 解析参数
		var args = JSON.parse_string(args_str)
		if args == null: args = {}
		
		# 执行工具
		#var result_str = tool_executor.execute_tool({"tool_name": tool_name, "arguments": args})
		
		# 调用工具并获取完整返回字典
		# 假设 ToolExecutor.execute_tool 已经改为返回整个 Dictionary 而不仅仅是 String
		# 如果 ToolExecutor 只返回 String，你需要在这里直接调用工具实例
		var tool_instance = ToolRegistry.get_tool(tool_name)
		var result_dict = tool_instance.execute(args, tool_executor.context_provider)
		
		var result_str = result_dict.get("data", "")
		
		# 创建 Tool Message
		# 传入 tool_name 以适配 Gemini
		var tool_msg = ChatMessage.new(ChatMessage.ROLE_TOOL, result_str, tool_name)
		tool_msg.tool_call_id = call_id
		
		# 处理图片附件
		if result_dict.has("attachments"):
			var att = result_dict.attachments
			tool_msg.image_data = att.get("image_data", [])
			tool_msg.image_mime = att.get("mime", "image/png")
		
		workflow_messages.append(tool_msg)
		emit_signal("tool_msg_generated", tool_msg)
	
	# 执行完一轮后，请求 AI 下一步
	_request_next_step()


func _request_next_step() -> void:
	# 构建上下文：基础历史 + 工作流产生的新消息
	var context = base_history + workflow_messages
	
	# 准备接收下一条助手消息
	temp_assistant_msg = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, "")
	
	# 连接网络信号
	if not network_manager.new_stream_chunk_received.is_connected(_on_chunk):
		network_manager.new_stream_chunk_received.connect(_on_chunk)
	if not network_manager.chat_stream_request_completed.is_connected(_on_stream_done):
		network_manager.chat_stream_request_completed.connect(_on_stream_done)
	
	network_manager.start_chat_stream(context)


# --- 网络回调 ---

func _on_chunk(chunk: Dictionary) -> void:
	# [修复] 无论是文本还是工具调用，都委托给 Provider 处理拼装
	# Provider 会自动处理 OpenAI 的增量合并或 Gemini 的全量更新
	if network_manager.current_provider:
		network_manager.current_provider.process_stream_chunk(temp_assistant_msg, chunk)
	else:
		# 极其罕见的后备逻辑 (防止 provider 丢失)
		if chunk.has("content"):
			temp_assistant_msg.content += chunk.content


func _on_stream_done() -> void:
	cleanup()
	
	# 检查这一步 AI 是否又调用了工具 (Multi-step Agent)
	if not temp_assistant_msg.tool_calls.is_empty():
		workflow_messages.append(temp_assistant_msg)
		_execute_tool_calls(temp_assistant_msg)
	else:
		# 工作流结束
		emit_signal("completed", temp_assistant_msg, workflow_messages)
