@tool
extends Node

# Agent 编排器
# 负责维护 Agent Runtime 唯一状态机、管理 AI 对话循环，并处理工具调用链的执行。
# 本类不解析任何协议、不直接改写消息数据、不直接持有 UI 引用：
# 协议解析由 Provider 负责，数据落地由 StreamMessageAssembler 负责，UI 通过信号响应式更新。


# --- Signals ---

# 当 Agent 运行状态发生变更时发出
signal state_changed(new_state: AgentState, status_payload: String)
# 当排队等待注入的用户输入条数变化时发出
signal pending_input_count_changed(count: int)


# --- Constants ---

const AIChatCurrentChatWindow = preload("res://addons/godot_ai_chat/scripts/ui/current_chat_window.gd")
const AIChatNetworkManager = preload("res://addons/godot_ai_chat/scripts/network/network_manager.gd")

const AttachmentProcessor := preload("res://addons/godot_ai_chat/scripts/helper/attachment_processor.gd")
const JSONRepairHelper := preload("res://addons/godot_ai_chat/scripts/helper/json_repair_helper.gd")
const ContextBuilder := preload("res://addons/godot_ai_chat/scripts/core/context_builder.gd")


# --- Enums ---

# Agent Runtime 核心状态定义（唯一状态源）
enum AgentState {
	IDLE,              # 空闲状态（唯一允许会话切换、压缩、发起新对话的状态）
	COMPRESSING,       # 正在压缩上下文
	WAITING_RESPONSE,  # 已发出请求，等待 LLM 首个流式数据块
	STREAMING,         # 正在接收并渲染 LLM 流式响应
	EXECUTING_TOOLS,   # 正在执行工具调用链
	STOPPING           # 已收到停止请求，等待当前网络收尾或运行中的工具返回
}


# --- Public Vars ---

var network_manager: AIChatNetworkManager
var current_chat_window: AIChatCurrentChatWindow


# --- Private Vars ---

# 当前唯一运行状态
var _state: AgentState = AgentState.IDLE

# 用户中途排队等待注入的输入（保存原始文本，注入时统一做附件解析）
var _pending_user_inputs: Array[String] = []


# --- Public Functions ---

# 获取当前状态
func get_state() -> AgentState:
	return _state


# 当前是否处于空闲态（唯一允许新建/加载/删除会话、压缩、发送新消息的状态）
func is_idle() -> bool:
	return _state == AgentState.IDLE


# 当前是否处于对话循环运行中（含正在停止收尾）
func is_running() -> bool:
	return _state in [
		AgentState.WAITING_RESPONSE,
		AgentState.STREAMING,
		AgentState.EXECUTING_TOOLS,
		AgentState.STOPPING
	]


# 当前是否已处于停止收尾流程中
func is_stopping() -> bool:
	return _state == AgentState.STOPPING


# 当前是否允许用户追加排队输入（STOPPING 与 COMPRESSING 期间不接受排队）
func can_queue_input() -> bool:
	return _state in [
		AgentState.WAITING_RESPONSE,
		AgentState.STREAMING,
		AgentState.EXECUTING_TOOLS
	]


# 请求状态机跃迁到新状态（带转换守卫）
# [param p_new_state]: 目标状态
# [param p_payload]: 附加给状态观察者（UI）的提示文案
# [return]: 转换是否生效
func transition_to(p_new_state: AgentState, p_payload: String = "") -> bool:
	if _state == p_new_state:
		if not p_payload.is_empty():
			state_changed.emit(_state, p_payload)
		return true
	
	if not _can_transition(_state, p_new_state):
		AIChatLogger.debug("[AgentState] Blocked invalid transition: %s -> %s" % [
			_get_state_name(_state),
			_get_state_name(p_new_state)
		])
		return false
	
	_state = p_new_state
	state_changed.emit(_state, p_payload)
	return true


# 通知状态机收到了流式数据块
# [return]: 当前是否允许继续处理并渲染该数据块（STOPPING 等状态下返回 false 以丢弃残留块）
func notify_stream_chunk_received() -> bool:
	if _state == AgentState.WAITING_RESPONSE:
		transition_to(AgentState.STREAMING)
		return true
	return _state == AgentState.STREAMING


# 请求取消当前工作流
func cancel_workflow() -> void:
	if not is_running():
		return
	
	var stop_payload: String = "Stopping generation..."
	if _state == AgentState.EXECUTING_TOOLS:
		stop_payload = "Stopping... waiting for the running tool to return."
	
	transition_to(AgentState.STOPPING, stop_payload)
	
	if network_manager:
		network_manager.cancel_stream()
	# 协作式通知技能代理收尾：它默认最多可跑 500 轮、单轮 180s 超时，
	# 不打通这条链路的话，「停止」在最耗时的场景下完全无效
	AIChatSkillAgentOrchestrator.request_cancel_all()


# 把一条用户输入压入等待队列
# [param p_text]: 用户原始输入
# [return]: 压入后的队列长度；返回 0 表示当前状态不接受排队
func queue_user_input(p_text: String) -> int:
	var trimmed: String = p_text.strip_edges()
	if trimmed.is_empty() or not can_queue_input():
		return 0
	
	_pending_user_inputs.append(trimmed)
	var count: int = _pending_user_inputs.size()
	pending_input_count_changed.emit(count)
	return count


# 取出队列中的全部输入并合并为单条文本（取出即清空）
# [return]: 合并后的文本；队列为空时返回空字符串
func take_pending_input() -> String:
	if _pending_user_inputs.is_empty():
		return ""
	
	var merged: String = "\n\n".join(_pending_user_inputs)
	_pending_user_inputs.clear()
	pending_input_count_changed.emit(0)
	return merged


# 当前排队中的输入条数
func get_pending_input_count() -> int:
	return _pending_user_inputs.size()


# 运行聊天循环
# [param p_base_history]: 基础历史记录
# [param p_settings]: 插件设置
func run_chat_cycle(p_base_history: ChatMessageHistory, p_settings: PluginSettingsConfig) -> void:
	# 入口守卫：仅允许从 IDLE 启动新一轮对话循环，彻底杜绝双协程重入
	if not is_idle():
		AIChatLogger.warn("[Main Agent] Cannot start chat cycle while in state: " + _get_state_name(_state))
		return
	
	while true:
		if is_stopping():
			break
		
		# [阶段3 · Bug3] 会话被外部切换：立即中止，避免后续写入污染新会话
		if current_chat_window.chat_history != p_base_history:
			AIChatLogger.warn("[Main Agent] Session switched during cycle. Aborting to avoid cross-session writes.")
			break
		
		# 新一轮网络请求开始，状态切为等待响应
		if not transition_to(AgentState.WAITING_RESPONSE):
			break
		
		# 使用 ContextBuilder 组装上下文
		var context: Array[ChatMessage] = ContextBuilder.build_context(p_base_history, p_settings)
		# 发起网络请求
		var response_result: Dictionary = await network_manager.request_chat_async(context)
		
		# 结局 1：用户主动点击了停止
		# 直接丢弃未完成的流式块（不入库、不写盘），避免「假入库 -> 回滚 -> 全量重绘」阻塞主线程
		if is_stopping():
			current_chat_window.discard_streaming_message()
			break
		
		# 结局 2：网络请求超时、断流或服务端报错
		# 剥离流式块（保留 UI 已渲染的半截思考/正文供排查，但绝不写入 ChatMessageHistory 污染上下文）
		if not response_result.success:
			current_chat_window.detach_streaming_message()
			current_chat_window.append_error_message(String(response_result.error))
			break
		
		# 结局 3：流式请求正常完成，正式刷出缓冲并将完整消息入库
		current_chat_window.flush_stream_buffer()
		
		var last_msg: ChatMessage = p_base_history.get_last_message()
		if last_msg == null or last_msg.role != ChatMessage.ROLE_ASSISTANT:
			break
		
		if last_msg.tool_calls.is_empty():
			# [阶段3] 模型已给出最终回答：若用户中途排了队，注入后继续跑一轮
			if _inject_pending_user_input(p_base_history) > 0:
				continue
			break
		
		var supports_inline: bool = network_manager.current_provider.supports_inline_tool_images()
		
		# 清洗工具调用：剔除伪调用（XML 包裹等），将被误判的文本抢救回 content
		var old_content_len: int = last_msg.content.length()
		ToolBox.salvage_and_clean_tool_calls(last_msg)
		
		# 如果发生了文本抢救，强制刷新 UI，把隐藏的文字显示出来
		if last_msg.content.length() > old_content_len:
			current_chat_window.refresh_display()
		
		# 如果清洗后发现全都是幻觉/误杀文本（空了），循环自然中止
		if last_msg.tool_calls.is_empty():
			# [阶段3] 同样先消化排队输入再决定是否结束
			if _inject_pending_user_input(p_base_history) > 0:
				continue
			break
		
		# 存在有效工具调用，正式进入执行阶段
		if not transition_to(AgentState.EXECUTING_TOOLS):
			break
		
		# 本轮工具返回的图片：先收集，等所有 tool 消息写完后统一注入。
		var pending_images: Array[Dictionary] = []
		
		for raw_call: Variant in last_msg.tool_calls:
			if is_stopping():
				break
			
			if not raw_call is Dictionary:
				continue
			
			var tc: Dictionary = raw_call
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
				if is_stopping():
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
			
			if not supports_inline and not image_data.is_empty():
				pending_images.append({
					"data": image_data,
					"mime": image_mime,
					"tool_name": tool_name,
				})
		
		if not is_stopping() and not pending_images.is_empty():
			var images: Array = []
			var tool_names: PackedStringArray = PackedStringArray()
			for img: Dictionary in pending_images:
				images.append({"data": img["data"], "mime": img["mime"]})
				tool_names.append(String(img["tool_name"]))
			current_chat_window.append_user_message(
				"Image content from tool(s): " + ", ".join(tool_names),
				images)
		
		_inject_pending_user_input(p_base_history)


# --- Private Functions ---

# 校验状态转换是否合法（状态机核心守卫表）
func _can_transition(p_from: AgentState, p_to: AgentState) -> bool:
	match p_from:
		AgentState.IDLE:
			return p_to in [AgentState.COMPRESSING, AgentState.WAITING_RESPONSE]
		AgentState.COMPRESSING:
			return p_to == AgentState.IDLE
		AgentState.WAITING_RESPONSE:
			return p_to in [
				AgentState.STREAMING,
				AgentState.EXECUTING_TOOLS,
				AgentState.STOPPING,
				AgentState.IDLE
			]
		AgentState.STREAMING:
			return p_to in [
				AgentState.EXECUTING_TOOLS,
				AgentState.WAITING_RESPONSE,
				AgentState.STOPPING,
				AgentState.IDLE
			]
		AgentState.EXECUTING_TOOLS:
			return p_to in [
				AgentState.WAITING_RESPONSE,
				AgentState.STOPPING,
				AgentState.IDLE
			]
		AgentState.STOPPING:
			# STOPPING 的唯一合法出口是等当前协程彻底收尾后回到 IDLE
			return p_to == AgentState.IDLE
	return false


# 获取状态名称（用于日志输出）
func _get_state_name(p_state: AgentState) -> String:
	match p_state:
		AgentState.IDLE: return "IDLE"
		AgentState.COMPRESSING: return "COMPRESSING"
		AgentState.WAITING_RESPONSE: return "WAITING_RESPONSE"
		AgentState.STREAMING: return "STREAMING"
		AgentState.EXECUTING_TOOLS: return "EXECUTING_TOOLS"
		AgentState.STOPPING: return "STOPPING"
	return "UNKNOWN"


# 把排队的用户输入合并为一条 user 消息注入历史
# 必须同时满足三个前提，任一不满足即放弃注入并保留队列：
# 1. 未处于停止流程 —— 停止后注入的 user 会成为回滚终点，导致整轮历史无法清理
# 2. 会话未被切换 —— 消息必须落进本次循环绑定的那本历史
# 3. 队列非空
# [param p_base_history]: 本次循环绑定的历史记录
# [return]: 注入的消息条数；0 表示未注入
func _inject_pending_user_input(p_base_history: ChatMessageHistory) -> int:
	if is_stopping() or _pending_user_inputs.is_empty():
		return 0
	if current_chat_window.chat_history != p_base_history:
		return 0
	
	var count: int = _pending_user_inputs.size()
	# 多条合并为一条发送，附件统一解析一次
	var merged: String = take_pending_input()
	var processed: Dictionary = AttachmentProcessor.process_input(merged)
	current_chat_window.append_user_message(processed.final_text, processed.images)
	
	return count
