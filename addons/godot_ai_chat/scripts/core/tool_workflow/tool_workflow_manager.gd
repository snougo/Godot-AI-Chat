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
	
	#for _call in _msg.tool_calls:
		#var _call_id: String = _call.get("id", "")
		#var _func_def: Dictionary = _call.get("function", {})
		#var _tool_name: String = _func_def.get("name", "")
		#var _raw_args_str: String = _func_def.get("arguments", "{}")
		
		#print("[Workflow] Executing tool: %s" % _tool_name)
	
	# [修复] 使用索引遍历，以便直接修改字典（引用类型），解决 ID 缺失问题
	for i in range(_msg.tool_calls.size()):
		var _call: Dictionary = _msg.tool_calls[i]
		
		var _call_id: String = _call.get("id", "")
		
		# [修复] ID 完整性检查
		# 部分模型流式输出时可能丢失 ID，或者 Godot 解析流时未能捕获。
		# 如果 ID 为空，手动生成一个默认 ID 并回填到 Assistant 消息中。
		if _call_id.is_empty():
			_call_id = "call_%d_%d" % [Time.get_ticks_msec(), i]
			_call["id"] = _call_id
			print("[Workflow] Fixed missing tool_call_id: %s" % _call_id)
		
		var _func_def: Dictionary = _call.get("function", {})
		var _tool_name: String = _func_def.get("name", "")
		var _raw_args_str: String = _func_def.get("arguments", "{}")
		
		print("[Workflow] Executing tool: %s (ID: %s)" % [_tool_name, _call_id])
		
		# 1. 清洗参数
		var _clean_args_str: String = _sanitize_json_arguments(_raw_args_str)
		# 更新原始消息中的参数字符串，保证历史记录整洁
		_func_def["arguments"] = _clean_args_str
		
		var _args: Variant = JSON.parse_string(_clean_args_str)
		if _args == null: 
			_args = {}
		
		# 2. 执行工具
		var _result_str: String = ""
		var _attachments: Dictionary = {}
		
		var _tool_instance: AiTool = ToolRegistry.get_tool(_tool_name)
		
		if not _tool_instance:
			# 工具不存在时，不跳过，而是返回错误信息给 LLM，保证对话链完整
			_result_str = "[SYSTEM ERROR] Tool '%s' not found. Execution failed." % _tool_name
			push_error("[Workflow] " + _result_str)
		else:
			# 支持异步执行
			var _result_dict: Dictionary = await _tool_instance.execute(_args)
			
			# 处理非字符串类型的data
			var _data_val: Variant = _result_dict.get("data", "")
			
			if _data_val is Dictionary or _data_val is Array:
				# 如果是字典或数组，转为带缩进的 JSON 字符串，方便 AI 阅读
				_result_str = JSON.stringify(_data_val, "\t")
			else:
				# 其他类型转为普通字符串
				_result_str = str(_data_val)
			
			if _result_dict.has("attachments"):
				_attachments = _result_dict.attachments
		
		# 3. 创建 Tool Message
		var _tool_msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_TOOL, _result_str, _tool_name)
		_tool_msg.tool_call_id = _call_id
		
		# 4. 处理图片附件
		if not _attachments.is_empty():
			var _att: Dictionary = _attachments
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
					# 注意：OpenAI 不允许 Tool Message 包含图片，必须另起一个 User 消息
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


## 清洗 JSON 字符串，去除 Markdown 包裹及尾部垃圾数据
func _sanitize_json_arguments(_json_str: String) -> String:
	_json_str = _json_str.strip_edges()
	
	# --- 1. 尝试剥离 Markdown 代码块 ---
	# 许多模型喜欢用 ```json ... ``` 包裹参数
	if _json_str.begins_with("```"):
		var _newline_index: int = _json_str.find("\n")
		if _newline_index != -1:
			# 提取从第一行换行符之后的内容
			var _content: String = _json_str.substr(_newline_index + 1)
			
			# 去除尾部的空白和 ``` 标记
			_content = _content.strip_edges()
			if _content.ends_with("```"):
				_content = _content.substr(0, _content.length() - 3)
			
			# 如果剥离后的内容能解析成功，直接返回
			_content = _content.strip_edges()
			if JSON.parse_string(_content) != null:
				return _content
			
			# 如果剥离后解析失败（比如内部还有截断），则让它继续走下面的截断修复逻辑，
			# 但使用已经剥离了外壳的 _content 作为基础
			_json_str = _content
	
	# --- 2. 尝试直接解析 ---
	if JSON.parse_string(_json_str) != null:
		return _json_str
	
	# --- 3. 截断修复逻辑 ---
	# 处理因 token 限制导致的 JSON 截断问题
	var _end_idx: int = _json_str.rfind("}")
	while _end_idx != -1:
		var _candidate: String = _json_str.substr(0, _end_idx + 1)
		if JSON.parse_string(_candidate) != null:
			return _candidate
		_end_idx = _json_str.rfind("}", _end_idx - 1)
	
	# 如果所有尝试都失败，返回空 JSON 对象防止崩溃
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
