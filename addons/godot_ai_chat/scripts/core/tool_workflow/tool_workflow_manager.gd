@tool
class_name ToolWorkflowManager
extends RefCounted

## 工具工作流管理器
##
## 负责管理工具调用的多步工作流（Agent 循环）。

# --- Signals ---

## 当工作流最终完成并获得最终回复时触发
signal completed(final_msg: ChatMessage, history: Array[ChatMessage])
## 当工作流执行失败时触发
signal failed(error: String)
## 当生成工具执行结果消息时触发
signal tool_msg_generated(msg: ChatMessage)

# --- Public Vars ---

## 网络管理器引用
var network_manager: NetworkManager
## 工具执行器引用
var tool_executor: ToolExecutor
## 初始聊天历史
var base_history: Array[ChatMessage]
## 本次工作流产生的新消息序列
var workflow_messages: Array[ChatMessage] = []

# --- Private Vars ---

## 临时存储正在接收的助手消息
var _temp_assistant_msg: ChatMessage

# --- Built-in Functions ---

func _init(p_nm: NetworkManager, p_te: ToolExecutor, p_history: Array[ChatMessage]) -> void:
	network_manager = p_nm
	tool_executor = p_te
	base_history = p_history

# --- Public Functions ---

## 清理资源并断开信号连接
func cleanup() -> void:
	if network_manager.new_stream_chunk_received.is_connected(_on_chunk):
		network_manager.new_stream_chunk_received.disconnect(_on_chunk)
	if network_manager.chat_stream_request_completed.is_connected(_on_stream_done):
		network_manager.chat_stream_request_completed.disconnect(_on_stream_done)


## 启动工作流
## [param p_trigger_msg]: 触发工具调用的助手消息
func start(p_trigger_msg: ChatMessage) -> void:
	_execute_tool_calls(p_trigger_msg)


# --- Private Functions ---

## 执行消息中的所有工具调用
func _execute_tool_calls(p_msg: ChatMessage) -> void:
	var generated_tool_msgs: Array[ChatMessage] = []
	
	# 使用索引遍历，以便直接修改字典（引用类型），解决 ID 缺失问题
	for i in range(p_msg.tool_calls.size()):
		var call: Dictionary = p_msg.tool_calls[i]
		var call_id: String = call.get("id", "")
		
		# ID 完整性检查
		# 部分模型流式输出时可能丢失 ID，或者 Godot 解析流时未能捕获。
		# 如果 ID 为空，手动生成一个默认 ID 并回填到 Assistant 消息中。
		if call_id.is_empty():
			call_id = "call_%d_%d" % [Time.get_ticks_msec(), i]
			call["id"] = call_id
			print("[Workflow] Fixed missing tool_call_id: %s" % call_id)
		
		var func_def: Dictionary = call.get("function", {})
		var tool_name: String = func_def.get("name", "")
		var raw_args_str: String = func_def.get("arguments", "{}")
		
		print("[Workflow] Executing tool: %s (ID: %s)" % [tool_name, call_id])
		
		# 1. 清洗参数
		# 使用 JSONRepairHelper 直接修复
		var clean_args_str: String = JSONRepairHelper.repair_json(raw_args_str)
		# 更新原始消息中的参数字符串，保证历史记录整洁
		func_def["arguments"] = clean_args_str
		
		var args: Variant = JSON.parse_string(clean_args_str)
		if args == null: 
			args = {}
		
		# 2. 执行工具
		var result_str: String = ""
		var attachments: Dictionary = {}
		
		var tool_instance: AiTool = ToolRegistry.get_tool(tool_name)
		
		if not tool_instance:
			# 工具不存在时，不跳过，而是返回错误信息给 LLM，保证对话链完整
			result_str = "[SYSTEM ERROR] Tool '%s' not found. Execution failed." % tool_name
			push_error("[Workflow] " + result_str)
		else:
			# 支持异步执行
			var result_dict: Dictionary = await tool_instance.execute(args)
			
			# 处理非字符串类型的data
			var data_val: Variant = result_dict.get("data", "")
			
			if data_val is Dictionary or data_val is Array:
				# 如果是字典或数组，转为带缩进的 JSON 字符串，方便 AI 阅读
				result_str = JSON.stringify(data_val, "\t")
			else:
				# 其他类型转为普通字符串
				result_str = str(data_val)
			
			if result_dict.has("attachments"):
				attachments = result_dict.attachments
		
		# 3. 创建 Tool Message
		var tool_msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_TOOL, result_str, tool_name)
		tool_msg.tool_call_id = call_id
		
		# 4. 处理图片附件
		if not attachments.is_empty():
			var att: Dictionary = attachments
			if att.has("image_data") and not att.image_data.is_empty():
				var is_gemini: bool = false
				if network_manager.current_provider:
					is_gemini = network_manager.current_provider is GeminiProvider
				
				if is_gemini:
					# Gemini 模式：直接嵌入 Tool 消息
					tool_msg.image_data = att.get("image_data", PackedByteArray())
					tool_msg.image_mime = att.get("mime", "image/png")
				else:
					# [Fix] OpenAI/Local 模式：
					# 不要创建新的 User 消息（会破坏对话链），而是将图片附加到最近的 User 消息上
					_attach_image_to_last_user_message(att.get("image_data", PackedByteArray()), att.get("mime", "image/png"))
					# 更新 Tool 消息文本，提示 LLM 图片已上传
					# 这对 LLM 来说是一个明确的信号，表明它现在可以去查看上下文中的图片了
					if tool_msg.content == "Image successfully read and attached to this message.":
						tool_msg.content = "Image content has been uploaded to the context. Please check the user message."
		
		generated_tool_msgs.append(tool_msg)
	
	# 5. 按顺序添加消息：先 Tool 后 User
	workflow_messages.append_array(generated_tool_msgs)
	for tm in generated_tool_msgs:
		tool_msg_generated.emit(tm)
	
	# 请求 AI 下一步
	_request_next_step()


## 将图片附加到历史记录中最近的一条 User 消息
func _attach_image_to_last_user_message(p_data: PackedByteArray, p_mime: String) -> void:
	# 优先检查本次工作流中产生的新消息
	for i in range(workflow_messages.size() - 1, -1, -1):
		if workflow_messages[i].role == ChatMessage.ROLE_USER:
			workflow_messages[i].image_data = p_data
			workflow_messages[i].image_mime = p_mime
			print("[Workflow] Attached image to Workflow User message index: %d" % i)
			return
	
	# 然后检查基础历史记录 (倒序)
	for i in range(base_history.size() - 1, -1, -1):
		if base_history[i].role == ChatMessage.ROLE_USER:
			base_history[i].image_data = p_data
			base_history[i].image_mime = p_mime
			print("[Workflow] Attached image to Base History User message index: %d" % i)
			return
	
	print("[Workflow] Warning: No User message found to attach image.")


## 请求 AI 进行下一步决策或最终回复
func _request_next_step() -> void:
	var context: Array[ChatMessage] = base_history + workflow_messages
	
	_temp_assistant_msg = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, "")
	
	if not network_manager.new_stream_chunk_received.is_connected(_on_chunk):
		network_manager.new_stream_chunk_received.connect(_on_chunk)
	if not network_manager.chat_stream_request_completed.is_connected(_on_stream_done):
		network_manager.chat_stream_request_completed.connect(_on_stream_done)
	
	network_manager.start_chat_stream(context)


# --- Signal Callbacks ---

func _on_chunk(p_chunk: Dictionary) -> void:
	if network_manager.current_provider:
		network_manager.current_provider.process_stream_chunk(_temp_assistant_msg, p_chunk)
	else:
		if p_chunk.has("content"):
			_temp_assistant_msg.content += p_chunk.content


func _on_stream_done() -> void:
	cleanup()
	
	# 检查是否需要多步循环
	if not _temp_assistant_msg.tool_calls.is_empty():
		workflow_messages.append(_temp_assistant_msg)
		_execute_tool_calls(_temp_assistant_msg)
	else:
		completed.emit(_temp_assistant_msg, workflow_messages)
