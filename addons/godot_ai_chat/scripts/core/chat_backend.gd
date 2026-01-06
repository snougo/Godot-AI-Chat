@tool
extends Node
class_name ChatBackend

signal assistant_message_ready(final_message: ChatMessage, workflow_history: Array[ChatMessage])
signal tool_message_generated(tool_message: ChatMessage)
signal tool_workflow_started
signal tool_workflow_failed(error: String)

var tool_executor = ToolExecutor.new()
var current_workflow: ToolWorkflowManager = null
var network_manager: NetworkManager
var current_chat_window: CurrentChatWindow

var is_in_workflow: bool = false


func cancel_workflow() -> void:
	if current_workflow:
		current_workflow.cleanup()
		current_workflow = null
	
	is_in_workflow = false


# 处理新的助手响应 (这是整个流程的入口)
# msg: 从流中构建完整的 ChatMessage 对象
func process_response(msg: ChatMessage) -> void:
	# 强制打印，看看最终收到了什么
	print("[ChatBackend] Processing response. Role: %s, Content len: %d, Tool calls: %d" % [msg.role, msg.content.length(), msg.tool_calls.size()])
	
	# [修复] 数据清洗：移除工具调用中的 XML 标签和非法字符
	if not msg.tool_calls.is_empty():
		for tool_call in msg.tool_calls:
			if tool_call.has("function"):
				var f = tool_call["function"]
				# 1. 清洗函数名
				if f.has("name") and f["name"] is String:
					f["name"] = f["name"].replace("<tool_call>", "").replace("</tool_call>", "").replace("tool_call", "").strip_edges()
				
				# 2. 尝试修复参数 JSON (如果是坏的 JSON)
				if f.has("arguments") and f["arguments"] is String:
					var args_str: String = f["arguments"]
					if JSON.parse_string(args_str) == null:
						# 如果解析失败，尝试截取到最后一个 }
						var last_brace = args_str.rfind("}")
						if last_brace != -1:
							var fixed_args = args_str.substr(0, last_brace + 1)
							if JSON.parse_string(fixed_args) != null:
								f["arguments"] = fixed_args
	
	# 检查是否有原生的工具调用
	if not msg.tool_calls.is_empty():
		_start_tool_workflow(msg)
	else:
		var history: Array[ChatMessage] = [msg]
		emit_signal("assistant_message_ready", msg, history)



func _start_tool_workflow(trigger_msg: ChatMessage) -> void:
	is_in_workflow = true
	emit_signal("tool_workflow_started")
	
	# [修复] 使用截断后的历史记录，而不是完整历史
	var settings = ToolBox.get_plugin_settings()
	var truncated_history = current_chat_window.chat_history.get_truncated_messages(
		settings.max_chat_turns,
		settings.system_prompt
	)
	
	current_workflow = ToolWorkflowManager.new(network_manager, tool_executor, truncated_history)
	current_workflow.completed.connect(_on_workflow_completed)
	current_workflow.failed.connect(_on_workflow_failed)
	current_workflow.tool_msg_generated.connect(func(m): emit_signal("tool_message_generated", m))
	
	# 启动工作流，直接传入包含 tool_calls 的消息
	current_workflow.start(trigger_msg)


func _on_workflow_completed(final_msg: ChatMessage, additional_history: Array[ChatMessage]) -> void:
	is_in_workflow = false
	current_workflow = null
	emit_signal("assistant_message_ready", final_msg, additional_history)


func _on_workflow_failed(err: String) -> void:
	is_in_workflow = false
	current_workflow = null
	emit_signal("tool_workflow_failed", err)
