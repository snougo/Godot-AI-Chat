@tool
class_name ChatBackend
extends Node

## 负责处理助手响应的后端逻辑，包括工具调用的识别、清洗和工作流管理。

# --- Signals ---

## 当助手消息最终准备就绪（包括工具调用完成后的最终回复）时触发
signal assistant_message_ready(final_message: ChatMessage, workflow_history: Array[ChatMessage])
## 当生成工具执行结果消息时触发
signal tool_message_generated(tool_message: ChatMessage)
## 工具工作流开始时触发
signal tool_workflow_started
## 工具工作流失败时触发
signal tool_workflow_failed(error: String)

# --- Public Vars ---

## 工具执行器实例
var tool_executor: ToolExecutor = ToolExecutor.new()
## 当前正在运行的工具工作流管理器
var current_workflow: ToolWorkflowManager = null
## 网络管理器引用
var network_manager: NetworkManager
## 当前聊天窗口引用
var current_chat_window: CurrentChatWindow
## 标记当前是否处于工具工作流中
var is_in_workflow: bool = false


# --- Public Functions ---

## 取消当前正在运行的工作流
func cancel_workflow() -> void:
	if current_workflow:
		current_workflow.cleanup()
		current_workflow = null
	
	is_in_workflow = false


## 处理新的助手响应（流程入口）
## [param _msg]: 从流中构建完整的 ChatMessage 对象
func process_response(_msg: ChatMessage) -> void:
	# 打印调试信息
	print("[ChatBackend] Processing response. Role: %s, Content len: %d, Tool calls: %d" % [_msg.role, _msg.content.length(), _msg.tool_calls.size()])
	
	# 使用 ToolBox 过滤掉思考过程中的幻觉工具调用
	#if not _msg.tool_calls.is_empty() and "<think>" in _msg.content:
		#_msg.tool_calls = ToolBox.filter_hallucinated_tool_calls(_msg.content, _msg.tool_calls)
	
	# 获取当前设置，判断是否为 Gemini
	var _settings: PluginSettings = ToolBox.get_plugin_settings()
	var _is_gemini: bool = (_settings.api_provider == "Google Gemini")
	
	# 使用 ToolBox 过滤掉思考过程中的幻觉工具调用
	# 增加判断：只有非 Gemini 且包含 <think> 时才执行过滤
	if not _is_gemini and not _msg.tool_calls.is_empty() and "<think>" in _msg.content:
		_msg.tool_calls = ToolBox.filter_hallucinated_tool_calls(_msg.content, _msg.tool_calls)
	
	# 数据清洗：移除工具调用中的 XML 标签和非法字符
	if not _msg.tool_calls.is_empty():
		for _tool_call in _msg.tool_calls:
			if _tool_call.has("function"):
				var tool_call_function: Dictionary = _tool_call["function"]
				# 1. 清洗函数名
				if tool_call_function.has("name") and tool_call_function["name"] is String:
					tool_call_function["name"] = tool_call_function["name"].replace("<tool_call>", "").replace("</tool_call>", "").replace("tool_call", "").strip_edges()
				
				# 2. 尝试修复参数 JSON (如果是坏的 JSON)
				if tool_call_function.has("arguments") and tool_call_function["arguments"] is String:
					# 使用 JSONRepairHelper 进行健壮的提取和修复
					var _raw_args: String = tool_call_function["arguments"]
					var _fixed_args: String = JSONRepairHelper.repair_json(_raw_args)
					
					# 验证修复结果，如果仍然无效，则回退到空对象
					if JSON.parse_string(_fixed_args) != null:
						tool_call_function["arguments"] = _fixed_args
					else:
						# 只有当原始参数完全不可救药时才这样做
						# 也可以保留原样让后续流程报错，这里选择安全回退
						tool_call_function["arguments"] = "{}" 
	
	# 检查是否有工具调用
	if not _msg.tool_calls.is_empty():
		_start_tool_workflow(_msg)
	else:
		var _history: Array[ChatMessage] = [_msg]
		assistant_message_ready.emit(_msg, _history)


# --- Private Functions ---

## 启动工具工作流
func _start_tool_workflow(_trigger_msg: ChatMessage) -> void:
	is_in_workflow = true
	tool_workflow_started.emit()
	
	# 使用截断后的历史记录，而不是完整历史
	var _settings: PluginSettings = ToolBox.get_plugin_settings()
	var _truncated_history: Array[ChatMessage] = current_chat_window.chat_history.get_truncated_messages(
		_settings.max_chat_turns,
		_settings.system_prompt,
		false
	)
	
	current_workflow = ToolWorkflowManager.new(network_manager, tool_executor, _truncated_history)
	current_workflow.completed.connect(_on_workflow_completed)
	current_workflow.failed.connect(_on_workflow_failed)
	current_workflow.tool_msg_generated.connect(func(_m: ChatMessage): tool_message_generated.emit(_m))
	
	# 启动工作流，直接传入包含 tool_calls 的消息
	current_workflow.start(_trigger_msg)


# --- Signal Callbacks ---

func _on_workflow_completed(_final_msg: ChatMessage, _additional_history: Array[ChatMessage]) -> void:
	is_in_workflow = false
	current_workflow = null
	assistant_message_ready.emit(_final_msg, _additional_history)


func _on_workflow_failed(_err: String) -> void:
	is_in_workflow = false
	current_workflow = null
	tool_workflow_failed.emit(_err)
