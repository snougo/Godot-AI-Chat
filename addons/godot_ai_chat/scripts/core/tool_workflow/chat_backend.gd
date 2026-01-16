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
	
	# 数据清洗：移除工具调用中的 XML 标签和非法字符
	if not _msg.tool_calls.is_empty():
		for _tool_call in _msg.tool_calls:
			if _tool_call.has("function"):
				var _f: Dictionary = _tool_call["function"]
				# 1. 清洗函数名
				if _f.has("name") and _f["name"] is String:
					_f["name"] = _f["name"].replace("<tool_call>", "").replace("</tool_call>", "").replace("tool_call", "").strip_edges()
				
				# 2. 尝试修复参数 JSON (如果是坏的 JSON)
				if _f.has("arguments") and _f["arguments"] is String:
					var _args_str: String = _f["arguments"]
					
					# 使用静默检测代替 JSON.parse_string 以避免控制台红字
					if not _is_valid_json(_args_str):
						# 如果解析失败，尝试截取到最后一个 }
						var _last_brace: int = _args_str.rfind("}")
						if _last_brace != -1:
							var _fixed_args: String = _args_str.substr(0, _last_brace + 1)
							if _is_valid_json(_fixed_args):
								_f["arguments"] = _fixed_args
	
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


## 辅助函数：静默检查 JSON 是否合法 (不打印 Error)
func _is_valid_json(_json_str: String) -> bool:
	var _json_obj: JSON = JSON.new()
	return _json_obj.parse(_json_str) == OK


# --- Signal Callbacks ---

func _on_workflow_completed(_final_msg: ChatMessage, _additional_history: Array[ChatMessage]) -> void:
	is_in_workflow = false
	current_workflow = null
	assistant_message_ready.emit(_final_msg, _additional_history)


func _on_workflow_failed(_err: String) -> void:
	is_in_workflow = false
	current_workflow = null
	tool_workflow_failed.emit(_err)
