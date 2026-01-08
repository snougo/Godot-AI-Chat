@tool
class_name ToolWorkflowManager
extends RefCounted

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

func _init(_nm: NetworkManager, _te: ToolExecutor, _history: Array[ChatMessage]) -> void:
	network_manager = _nm
	tool_executor = _te
	base_history = _history

# --- Public Functions ---

## 清理资源并断开信号连接
func cleanup() -> void:
	if network_manager.new_stream_chunk_received.is_connected(_on_chunk):
		network_manager.new_stream_chunk_received.disconnect(_on_chunk)
	if network_manager.chat_stream_request_completed.is_connected(_on_stream_done):
		network_manager.chat_stream_request_completed.disconnect(_on_stream_done)


## 启动工作流
## [param _trigger_msg]: 触发工具调用的助手消息
func start(_trigger_msg: ChatMessage) -> void:
	_execute_tool_calls(_trigger_msg)

# --- Private Functions ---

## 执行消息中的所有工具调用
func _execute_tool_calls(_msg: ChatMessage) -> void:
	var _generated_tool_msgs: Array[ChatMessage] = []
	var _generated_image_msgs: Array[ChatMessage] = []

	for _call in _msg.tool_calls:
		var _call_id: String = _call.get("id", "")
		var _func_def: Dictionary = _call.get("function", {})
		var _tool_name: String = _func_def.get("name", "")
		var _raw_args_str: String = _func_def.get("arguments", "{}")
		
		print("[Workflow] Executing tool: %s" % _tool_name)
		
		# 1. 清洗参数
		var _clean_args_str: String = _sanitize_json_arguments(_raw_args_str)
		_func_def["arguments"] = _clean_args_str
		
		var _args: Variant = JSON.parse_string(_clean_args_str)
		if _args == null: 
			_args = {}
		
		# 2. 执行工具
		var _tool_instance: AiTool = ToolRegistry.get_tool(_tool_name)
		if not _tool_instance:
			push_error("[Workflow] Tool not found: " + _tool_name)
			continue
		
		# 支持异步执行
		var _result_dict: Dictionary = await _tool_instance.execute(_args, tool_executor.context_provider)
		var _result_str: String = _result_dict.get("data", "")
		
		# 3. 创建 Tool Message
		var _tool_msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_TOOL, _result_str, _tool_name)
		_tool_msg.tool_call_id = _call_id
		
		# 4. 处理图片附件
		if _result_dict.has("attachments"):
			var _att: Dictionary = _result_dict.attachments
			if _att.has("image_data") and not _att.image_data.is_empty():
				var _is_gemini: bool = false
				if network_manager.current_provider:
					_is_gemini = network_manager.current_provider is GeminiProvider
				
				if _is_gemini:
					# Gemini 模式：直接嵌入 Tool 消息
					_tool_msg.image_data = _att.get("image_data", PackedByteArray())
					_tool_msg.image_mime = _att.get("mime", "image/png")
				else:
					# OpenAI/Local 模式：转换为额外的 User 消息
					var _image_msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_USER, "Image content from tool '%s':" % _tool_name)
					_image_msg.image_data = _att.get("image_data", PackedByteArray())
					_image_msg.image_mime = _att.get("mime", "image/png")
					_generated_image_msgs.append(_image_msg)
		
		_generated_tool_msgs.append(_tool_msg)
	
	# 5. 按顺序添加消息：先 Tool 后 User
	workflow_messages.append_array(_generated_tool_msgs)
	for _tm in _generated_tool_msgs:
		tool_msg_generated.emit(_tm)
	
	workflow_messages.append_array(_generated_image_msgs)
	for _im in _generated_image_msgs:
		tool_msg_generated.emit(_im)
	
	# 请求 AI 下一步
	_request_next_step()


## 请求 AI 进行下一步决策或最终回复
func _request_next_step() -> void:
	var _context: Array[ChatMessage] = base_history + workflow_messages
	
	_temp_assistant_msg = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, "")
	
	if not network_manager.new_stream_chunk_received.is_connected(_on_chunk):
		network_manager.new_stream_chunk_received.connect(_on_chunk)
	if not network_manager.chat_stream_request_completed.is_connected(_on_stream_done):
		network_manager.chat_stream_request_completed.connect(_on_stream_done)
	
	network_manager.start_chat_stream(_context)


## 清洗 JSON 字符串，去除尾部垃圾数据
func _sanitize_json_arguments(_json_str: String) -> String:
	_json_str = _json_str.strip_edges()
	
	if JSON.parse_string(_json_str) != null:
		return _json_str
	
	var _end_idx: int = _json_str.rfind("}")
	while _end_idx != -1:
		var _candidate: String = _json_str.substr(0, _end_idx + 1)
		if JSON.parse_string(_candidate) != null:
			return _candidate
		_end_idx = _json_str.rfind("}", _end_idx - 1)
	
	return "{}"

# --- Signal Callbacks ---

func _on_chunk(_chunk: Dictionary) -> void:
	if network_manager.current_provider:
		network_manager.current_provider.process_stream_chunk(_temp_assistant_msg, _chunk)
	else:
		if _chunk.has("content"):
			_temp_assistant_msg.content += _chunk.content


func _on_stream_done() -> void:
	cleanup()
	
	# 检查是否需要多步循环
	if not _temp_assistant_msg.tool_calls.is_empty():
		workflow_messages.append(_temp_assistant_msg)
		_execute_tool_calls(_temp_assistant_msg)
	else:
		completed.emit(_temp_assistant_msg, workflow_messages)
