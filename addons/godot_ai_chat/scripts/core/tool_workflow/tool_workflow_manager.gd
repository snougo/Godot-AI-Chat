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


func _execute_tool_calls(_msg: ChatMessage) -> void:
	# 收集本轮产生的所有消息
	var generated_tool_msgs: Array[ChatMessage] = []
	var generated_image_msgs: Array[ChatMessage] = []

	# 遍历执行所有工具
	for call in _msg.tool_calls:
		var call_id = call.get("id", "")
		var func_def = call.get("function", {})
		var tool_name = func_def.get("name", "")
		var raw_args_str = func_def.get("arguments", "{}")
		
		print("[Workflow] Executing tool: %s" % tool_name)
		
		# 1. 清洗参数 (保留之前的修复)
		var clean_args_str: String = self._sanitize_json_arguments(raw_args_str)
		func_def["arguments"] = clean_args_str
		
		var args = JSON.parse_string(clean_args_str)
		if args == null: args = {}
		
		# 2. 执行工具
		var tool_instance: AiTool = ToolRegistry.get_tool(tool_name)
		if not tool_instance:
			push_error("[Workflow] Tool not found: " + tool_name)
			continue
		
		# 直接调用实例以获取完整字典 (包含 attachments)
		var result_dict: Dictionary = tool_instance.execute(args, tool_executor.context_provider)
		var result_str = result_dict.get("data", "")
		
		# 3. 创建 Tool Message (默认为纯文本)
		var tool_msg := ChatMessage.new(ChatMessage.ROLE_TOOL, result_str, tool_name)
		tool_msg.tool_call_id = call_id
		
		# 4. 处理图片附件
		if result_dict.has("attachments"):
			var att = result_dict.attachments
			if att.has("image_data") and not att.image_data.is_empty():
				# [修复] 区分 Provider 类型
				# Gemini 支持在 Tool 消息中直接嵌入图片 (多模态)
				# OpenAI/Local 兼容性较差，需要转换为额外的 User 消息
				var is_gemini := false
				if network_manager.current_provider:
					is_gemini = network_manager.current_provider is GeminiProvider
				
				if is_gemini:
					# Gemini 模式：直接嵌入 Tool 消息
					tool_msg.image_data = att.get("image_data", [])
					tool_msg.image_mime = att.get("mime", "image/png")
				else:
					# OpenAI/Local 模式：转换为额外的 User 消息
					var image_msg := ChatMessage.new(ChatMessage.ROLE_USER, "Image content from tool '%s':" % tool_name)
					image_msg.image_data = att.get("image_data", [])
					image_msg.image_mime = att.get("mime", "image/png")
					generated_image_msgs.append(image_msg)
		
		generated_tool_msgs.append(tool_msg)
	
	# 5. 按顺序添加消息：先 Tool 后 User
	# OpenAI 要求 Tool Messages 必须紧跟在 Assistant Message 之后，中间不能插队
	workflow_messages.append_array(generated_tool_msgs)
	for tm in generated_tool_msgs:
		emit_signal("tool_msg_generated", tm)
	
	# 随后追加图片消息 (仅在非 Gemini 模式下会有内容)
	workflow_messages.append_array(generated_image_msgs)
	for im in generated_image_msgs:
		emit_signal("tool_msg_generated", im)
	
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


# --- 辅助函数 ---

# 清洗 JSON 字符串，去除尾部可能导致 400 错误的垃圾数据
func _sanitize_json_arguments(json_str: String) -> String:
	json_str = json_str.strip_edges()
	
	# 1. 尝试直接解析
	if JSON.parse_string(json_str) != null:
		return json_str
	
	# 2. 如果解析失败（如 Expected 'EOF'），尝试从后往前寻找合法的闭合点
	# 例如: '{"a":1} \n' -> '{"a":1}'
	var end_idx = json_str.rfind("}")
	while end_idx != -1:
		var candidate = json_str.substr(0, end_idx + 1)
		if JSON.parse_string(candidate) != null:
			return candidate
		# 继续往前找下一个 '}' (处理嵌套结构)
		end_idx = json_str.rfind("}", end_idx - 1)
	
	# 3. 实在无法修复，返回空 JSON 对象，避免 crash
	return "{}"


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
