@tool
class_name AIChatSkillAgentOrchestrator
extends Node

# Skill Agent 编排器
# 使用技能（Skill）声明的工具集独立完成一个任务，并回报结果。
# 与 Main Agent 完全隔离：独立历史、独立工具集、独立 Provider 实例。
# 网络层与 Main Agent 共用同一套 StreamRequest 实现，隔离性由「独立实例」而非「独立实现」保证。


# --- Constants ---

const ContextBuilder := preload("res://addons/godot_ai_chat/scripts/core/context_builder.gd")
const StreamMessageAssembler := preload("res://addons/godot_ai_chat/scripts/core/stream_message_assembler.gd")
const StreamRequest := preload("res://addons/godot_ai_chat/scripts/network/stream_request.gd")
const JSONRepairHelper := preload("res://addons/godot_ai_chat/scripts/helper/json_repair_helper.gd")

const REPORT_TASK_TOOL_SCRIPT: Resource = preload("res://addons/godot_ai_chat/scripts/tools/skill_agent_tool/report_task_result_tool.gd")

# 控制台流式输出段落标识（空串表示当前没有打开的段落）
const CONSOLE_SEGMENT_THINKING: String = "thinking"
const CONSOLE_SEGMENT_CONTENT: String = "content"

# 控制台流式输出的行缓冲刷新阈值（字符数）
# [为什么需要] 编辑器 Output 面板按整行追加，长时间没有换行的内容不会显示；
# 累积到该长度即强制作为一行输出，兼顾「实时可见」与「不刷屏」
const CONSOLE_FLUSH_THRESHOLD: int = 160

# --- 重试策略 ---
# 可重试的 HTTP 状态码：429 限流 + 上游临时故障
# [为什么不含 4xx 其它码] 配置/参数错误，重试只是浪费配额和时间
# [为什么不含超时与连接失败] network_timeout 默认 180s，重试会把一次失败放大成数分钟卡死
const RETRYABLE_STATUS_CODES: Array[int] = [429, 500, 502, 503, 504]
# 最大重试次数（不含首次请求），即最多发出 RETRY_MAX_ATTEMPTS + 1 次请求
const RETRY_MAX_ATTEMPTS: int = 3
# 指数退避基础秒数：10 → 20 → 40
const RETRY_BASE_DELAY_S: float = 10.0
# 单次等待上限：服务端可能回 Retry-After: 3600，必须夹住
const RETRY_MAX_DELAY_S: float = 60.0
# 抖动比例：避免多个客户端在同一时刻集体重试，把限流窗口再次撞满
const RETRY_JITTER_RATIO: float = 0.2

# 取消时的统一返回文案
# [为什么要点明「未回滚」] 取消发生在工具执行之后时，工具的副作用（写文件等）已经生效，
# 主代理需要知道这一点，否则会误判为「什么都没发生」而重复执行
const CANCELLED_RESULT_MESSAGE: String = "Skill Agent was cancelled by the user before completion. Its task may be partially completed. Any files it already wrote have NOT been rolled back; please verify the current state before retrying."


# --- Public Vars ---

var skill_name: String = ""
var task_description: String = ""


# --- Private Vars ---

var _config: SkillAgentConfig
var _history: ChatMessageHistory
var _skill_agent_tools: Dictionary = {}

# 控制台流式输出：当前打开的段落
# [为什么需要状态] 流式增量是碎片化的，段落标题只能在首块打印一次；
# 段落切换 / 结束时必须补换行，否则多段文本会挤在同一行。
var _console_segment: String = ""

# 控制台输出行缓冲：编辑器面板按整行刷新，故先缓冲再整行输出
var _console_line_buffer: String = ""

# 协作式取消标志：置位后由主循环在各检查点自行收尾并正常返回
# [为什么不直接 queue_free] 节点被释放会让 run_task() 永不返回，
# 主代理的 await tool_instance.execute() 将永久挂起，整个聊天循环卡死
var _is_cancelled: bool = false

# 活动实例登记表（供插件停用时统一释放）
static var _active_instances: Array[AIChatSkillAgentOrchestrator] = []


# --- Built-in Functions ---

func _exit_tree() -> void:
	_active_instances.erase(self)
	_clean_reference()
	AIChatLogger.info("[Skill Agent] Removed from scene tree and ready to free.")


func _ready() -> void:
	if not _active_instances.has(self):
		_active_instances.append(self)


# --- Public Functions ---

func run_task() -> String:
	# 每次任务开始前复位取消标志：本类是 Node，实例理论上可能被复用；
	# 与 Main Agent 的 is_cancelled 一样，粘滞标志必须在入口处清空
	_is_cancelled = false
	
	# 优先使用技能级配置，若无则回退到全局配置
	var skill_res: Resource = ToolRegistry.available_skills.get(skill_name)
	if skill_res and skill_res.get("skill_agent_config") != null:
		_config = skill_res.skill_agent_config
	else:
		_config = SkillAgentConfig.get_config()
	
	_history = ChatMessageHistory.new()
	
	AIChatLogger.info("[Skill Agent] Starting task with skill: '%s'" % skill_name)
	
	# 1. 加载工具
	_load_isolated_tools()
	
	# 2. 组装上下文（委托给 ContextBuilder）
	var context_messages: Array[ChatMessage] = ContextBuilder.build_skill_agent_context(
		_config.base_system_prompt,
		skill_name,
		task_description
	)
	
	for msg: ChatMessage in context_messages:
		_history.add_message(msg)
	
	# 3. 准备 Provider
	if _config.model_name.is_empty():
		var err: String = "Error: Skill Agent startup failed: model name is empty. Please configure it before invoking."
		AIChatLogger.error(err)
		_remove_skill_agent()
		return err
	
	var provider: BaseLLMProvider = ProviderFactory.create_provider(_config.api_provider)
	if not provider:
		_remove_skill_agent()
		return "Error: failed to initialize Skill Agent API Provider."
	
	# 告知 Provider 目标模型与端点：下方能力查询（schema 方言 / inline 图片）
	# 发生在 build_request_body() 之前，无法通过请求参数传入
	provider.set_active_model_name(_config.model_name)
	provider.set_active_base_url(_config.api_base_url)
	
	# 工具定义方言与图片交付方式均由 Provider 以能力查询自行声明
	var requires_gemini_schema: bool = provider.requires_gemini_tool_schema()
	var supports_inline: bool = provider.supports_inline_tool_images()
	
	# 4. 主循环（统一走 StreamRequest：后台线程网络 IO，主线程解析与落地）
	var turns_taken: int = 0
	var final_report: String = ""
	var has_reported: bool = false
	
	# 步骤提醒阈值：剩余步数 ≤ 总步数 10% 时才注入计数提示
	# [为什么不每轮注入] 每轮约数十 tokens，长任务下累计可观；且临近上限时模型才真正需要这类信息
	var step_warn_threshold: int = ContextBuilder.get_step_warn_threshold(_config.max_chat_turns)
	# 仅用于避免在提醒期内每轮刷一条日志
	var step_notice_logged: bool = false
	
	while turns_taken < _config.max_chat_turns:
		# [阶段2 · 取消检查点 1] 每轮开始前
		if _is_cancelled:
			AIChatLogger.warn("[Skill Agent] Cancelled by user before turn %d." % (turns_taken + 1))
			_remove_skill_agent()
			return CANCELLED_RESULT_MESSAGE
		
		turns_taken += 1
		
		# 轮次分隔：流式输出需要明确的上下文边界，否则多轮内容在控制台里首尾相连
		_close_console_segment()
		AIChatLogger.info("[Skill Agent] --- Turn %d ---" % turns_taken)
		
		# 构建流式请求
		var tool_defs: Array[Dictionary] = _get_tool_definitions(requires_gemini_schema)
		
		# 步骤计数提示：仅在剩余步数进入最后 10% 时，追加到「请求副本」末尾，不写入 _history
		# [为什么不改 system / 不改旧消息] KV(Prompt) 缓存按「从头算起的最长公共前缀」命中：
		# system prompt 或任何已发送过的消息一旦变动，其后内容全部失效；
		# 而末尾追加只会重算这一条，历史前缀照常命中，成本为零。
		var used_steps: int = turns_taken - 1
		var request_messages: Array[ChatMessage] = _history.messages
		if _config.max_chat_turns - used_steps <= step_warn_threshold:
			if not step_notice_logged:
				step_notice_logged = true
				AIChatLogger.info("[Skill Agent] Step budget running low: %d / %d consumed." % [used_steps, _config.max_chat_turns])
			request_messages = ContextBuilder.append_step_counter(_history.messages, used_steps, _config.max_chat_turns)
		
		var body: Dictionary = provider.build_request_body(_config.model_name, request_messages, _config.temperature, true, tool_defs)
		var url: String = provider.get_request_url(_config.api_base_url, _config.model_name, _config.api_key, true)
		var headers: PackedStringArray = provider.get_request_headers(_config.api_key, true)
		
		# 统一流式请求（带重试）：请求体以 Dictionary 传入，序列化推迟到后台线程；
		# 协议分派由 provider.parse_stream_chunk 决定；仅 429 / 5xx 走指数退避重试
		var response: Dictionary = await _do_stream_request_with_retry(url, headers, body, provider, _config.network_timeout)
		
		# [阶段2 · 取消检查点 2] 请求返回后
		# [为什么不能只看 response.has("error")] 取消路径返回的 error 文案与真实失败难以区分，
		# 这里用标志位判定，保证取消得到明确的返回值
		if _is_cancelled:
			AIChatLogger.warn("[Skill Agent] Cancelled by user while awaiting response.")
			_remove_skill_agent()
			return CANCELLED_RESULT_MESSAGE
		
		if response.has("error"):
			AIChatLogger.error("[Skill Agent] " + String(response.error))
			_remove_skill_agent()
			return String(response.error)
		
		var content: String = String(response.get("content", ""))
		var reasoning: String = String(response.get("reasoning_content", ""))
		var raw_tool_calls: Variant = response.get("tool_calls", [])
		var response_tool_calls: Array = raw_tool_calls if raw_tool_calls is Array else []
		
		# 思考 / 正文已在流式接收过程中实时打印到控制台，此处不再整段重复输出
		
		if content.is_empty() and not response_tool_calls.is_empty():
			content = " "
		
		var assistant_msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_ASSISTANT, content)
		assistant_msg.reasoning_content = reasoning
		assistant_msg.tool_calls = response_tool_calls
		
		# 回传 Anthropic extended-thinking 块的签名，多轮 thinking 会话必需
		var thinking_signature: String = String(response.get("thinking_signature", ""))
		if not thinking_signature.is_empty():
			assistant_msg.metadata[ChatMessage.META_THINKING_SIGNATURE] = thinking_signature
		
		# 清洗工具调用：剔除伪调用（XML 包裹等），将被误判的文本抢救回 content
		ToolBox.salvage_and_clean_tool_calls(assistant_msg, _skill_agent_tools)
		_history.add_message(assistant_msg)
		
		var clean_tool_calls: Array = assistant_msg.tool_calls
		
		if clean_tool_calls.is_empty():
			_remove_skill_agent()
			AIChatLogger.warn("[Skill Agent] Stopped without reporting.")
			return "Skill Agent stopped without reporting a result. Please check the status of the relevant files."
		
		# 收集本轮工具返回的图片附件
		var pending_images: Array[Dictionary] = []
		
		# 执行工具
		for raw_call: Variant in clean_tool_calls:
			# [阶段2 · 取消检查点 3] 每个工具执行前
			# 已开始的 execute() 无法中断，但可以阻止后续工具继续执行
			if _is_cancelled:
				AIChatLogger.warn("[Skill Agent] Cancelled by user during tool execution.")
				_remove_skill_agent()
				return CANCELLED_RESULT_MESSAGE
			
			if not raw_call is Dictionary:
				continue
			var tc: Dictionary = raw_call
			
			var func_dict: Dictionary = tc.get("function", {})
			var t_name: String = String(func_dict.get("name", ""))
			var args_str: String = String(func_dict.get("arguments", "{}"))
			var call_id: String = String(tc.get("id", ""))
			
			var t_args: Variant = JSON.parse_string(JSONRepairHelper.repair_json(args_str))
			if t_args == null:
				t_args = {}
			
			AIChatLogger.info("[Skill Agent] Executing Tool: " + t_name)
			
			if t_name == "report_task_result":
				final_report = "Status: %s\nSummary: %s" % [t_args.get("status", "unknown"), t_args.get("summary", "")]
				has_reported = true
				break
			
			var tool_inst: AiTool = _skill_agent_tools.get(t_name)
			
			var t_result: String = ""
			if tool_inst:
				var res: ToolResult = await tool_inst.execute(t_args)
				
				# [阶段2 · 取消检查点 4] 工具返回后
				# 副作用已发生，此处不再写入历史，直接以「已取消」收尾
				if _is_cancelled:
					AIChatLogger.warn("[Skill Agent] Cancelled by user after tool '%s' returned." % t_name)
					_remove_skill_agent()
					return CANCELLED_RESULT_MESSAGE
				
				# 先获取结果文本
				t_result = res.get_data()
				
				AIChatLogger.debug("[Skill Agent] Tool Result: " + t_result)
				
				if res.has_image():
					if supports_inline:
						# 支持 inline 图片的 Provider：图片直接放入 tool 消息
						var tool_msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_TOOL, t_result, t_name)
						tool_msg.tool_call_id = call_id
						tool_msg.add_image(res.attachments.image_data, res.attachments.mime)
						_history.add_message(tool_msg)
					else:
						# 不支持 inline 图片的 Provider: 收集图片，稍后通过新增 User 消息承载
						pending_images.append({
							"data": res.attachments.image_data,
							"mime": res.attachments.get("mime", "image/png"),
							"tool_name": t_name
						})
						_history.add_tool_message(t_result, call_id, t_name)
				else:
					_history.add_tool_message(t_result, call_id, t_name)
			else:
				t_result = "[ERROR] Tool not found: " + t_name
				_history.add_tool_message(t_result, call_id, t_name)
		
		# 仅当 Provider 不支持 inline tool 图片 且模型支持视觉(VLM)时，才将图片以 User 消息注入
		if not supports_inline and _config.supports_vision and not pending_images.is_empty():
			var img_msg: ChatMessage = ChatMessage.new(ChatMessage.ROLE_USER, "The following images were retrieved from tool execution. Please analyze their content.")
			for img: Dictionary in pending_images:
				img_msg.add_image(img["data"], img["mime"])
			_history.add_message(img_msg)
		
		if has_reported:
			_remove_skill_agent()
			AIChatLogger.info("[Skill Agent] Task Finished.")
			return final_report
	
	_remove_skill_agent()
	AIChatLogger.warn("[Skill Agent] Exceeded max turns.")
	return "Skill Agent reached the maximum execution step limit and was forcibly terminated." \
	+ "Its task has been partially completed." \
	+ "Please re-invoke the Skill Agent to continue from where it left off."


# 请求取消当前任务（协作式）
# 仅置位标志，由 run_task() 在下列检查点自行收尾并正常返回：
#   1. 每轮循环开头
#   2. 每个工具执行前
#   3. 工具 execute() 返回后
#   4. 流式请求等待期间（主线程逐帧检测）
#   5. 重试退避倒计时期间
func request_cancel() -> void:
	_is_cancelled = true


# 请求取消所有活动实例（协作式，不会造成主代理 await 永久挂起）
# [与 cancel_all() 的区别] cancel_all() 用于插件停用时的硬释放（queue_free）；
# 运行中的取消必须走本方法，否则协程被中断会导致调用方永久阻塞。
static func request_cancel_all() -> void:
	for instance: AIChatSkillAgentOrchestrator in _active_instances:
		if is_instance_valid(instance):
			instance.request_cancel()


# 释放全部活动 Skill Agent（插件停用时调用）
static func cancel_all() -> void:
	for instance: AIChatSkillAgentOrchestrator in _active_instances.duplicate():
		if is_instance_valid(instance):
			instance.queue_free()
	_active_instances.clear()


# --- Private Functions ---

# 带重试的流式请求
# 只对「等一会就好」的服务端错误（429 / 5xx）做指数退避重试：
# 配置错误（4xx）与超时类错误直接失败返回，重试无意义或代价过高。
# [param ...]: 同 _do_stream_request()
# [return]: 同 _do_stream_request()；重试耗尽后返回最后一次的错误结果
func _do_stream_request_with_retry(p_url: String, p_headers: PackedStringArray, p_body: Dictionary, p_provider: BaseLLMProvider, p_timeout_s: int) -> Dictionary:
	var attempt: int = 0
	var response: Dictionary = await _do_stream_request(p_url, p_headers, p_body, p_provider, p_timeout_s)
	
	while response.has("error"):
		# [阶段2 · 取消检查点 5] 取消后不再重试
		if _is_cancelled:
			break
		
		var status_code: int = int(response.get("status_code", 0))
		# 重试预算用尽，或错误类型不可重试 → 直接返回最后一次结果
		if attempt >= RETRY_MAX_ATTEMPTS or not RETRYABLE_STATUS_CODES.has(status_code):
			break
		
		attempt += 1
		# 防御性收尾：非 200 时不会输出正文，但保证段落状态干净
		_close_console_segment()
		var delay: float = _compute_retry_delay(attempt, float(response.get("retry_after", -1.0)))
		await _wait_before_retry(delay, attempt, status_code)
		
		response = await _do_stream_request(p_url, p_headers, p_body, p_provider, p_timeout_s)
	
	return response


# 计算下一次重试的等待时长
# [param p_attempt]: 当前是第几次重试（从 1 开始）
# [param p_retry_after_s]: 服务端建议的等待秒数（-1 表示无建议）
func _compute_retry_delay(p_attempt: int, p_retry_after_s: float) -> float:
	var delay: float = p_retry_after_s
	if delay <= 0.0:
		delay = RETRY_BASE_DELAY_S * pow(2.0, p_attempt - 1)
		# 抖动只向上加：负数抖动会让实际等待短于计算值，反而更容易再次撞上 429
		delay *= 1.0 + randf_range(0.0, RETRY_JITTER_RATIO)
	
	return clampf(delay, 1.0, RETRY_MAX_DELAY_S)


# 重试前等待，并逐秒输出倒计时
# [为什么用 WARN 而不是 DEBUG] 退避期间 Skill Agent 看起来像「卡死了」，
# 用户必须在默认日志通道下就能分辨"限流等待"与"死锁"。
# [param p_seconds]: 本次等待总秒数
# [param p_attempt]: 当前是第几次重试（从 1 开始）
# [param p_status_code]: 触发重试的 HTTP 状态码
func _wait_before_retry(p_seconds: float, p_attempt: int, p_status_code: int) -> void:
	var total: int = int(roundf(p_seconds))
	AIChatLogger.warn("[Skill Agent] HTTP %d — retry %d/%d in %ds." % [p_status_code, p_attempt, RETRY_MAX_ATTEMPTS, total])
	
	var remaining: int = total
	while remaining > 0:
		# [取消检查点] 进入等待前
		if _is_cancelled:
			AIChatLogger.warn("[Skill Agent] Retry cancelled by user.")
			return
		
		await get_tree().create_timer(1.0).timeout
		
		# [取消检查点] 等待唤醒后立即复查：
		# 否则取消最多要等满 1 秒才被感知，且倒计时归零时会跳过本函数直接进入下一次请求
		if _is_cancelled:
			AIChatLogger.warn("[Skill Agent] Retry cancelled by user.")
			return
		
		remaining -= 1
		if remaining > 0:
			AIChatLogger.warn("[Skill Agent] Retry countdown: %ds" % remaining)


# 统一的流式网络请求（与主链路共用 StreamRequest 实现与主线程看门狗）
func _do_stream_request(p_url: String, p_headers: PackedStringArray, p_body: Dictionary, p_provider: BaseLLMProvider, p_timeout_s: int) -> Dictionary:
	if _is_cancelled:
		return {"error": "Cancelled by user.", "status_code": 0, "retry_after": -1.0}
	
	# 重置 Provider 流内状态（槽位映射、用量累计等），必须在请求发出前完成
	p_provider.reset_stream_state()
	
	var request: StreamRequest = StreamRequest.new(
		p_provider,
		p_url,
		p_headers,
		p_body,
		TimeoutTracker.from_network_timeout(p_timeout_s)
	)
	
	var assembler: StreamMessageAssembler = StreamMessageAssembler.new()
	assembler.begin()
	
	request.delta_received.connect(func(p_delta: LLMStreamDelta) -> void:
		if _is_cancelled:
			return
		_console_print_delta(p_delta)
		assembler.apply(p_delta)
	)
	
	request.start()
	
	# 主线程每帧驱动看门狗并检查取消，直至请求进入唯一终态
	while not request.is_settled():
		if _is_cancelled:
			request.cancel()
			request.request_thread_cleanup()
			_close_console_segment()
			return {"error": "Cancelled by user.", "status_code": 0, "retry_after": -1.0}
		
		request.poll_watchdog()
		if request.is_settled():
			break
		
		await get_tree().process_frame
	
	# 非阻塞回收线程池任务槽位，避免 WorkerThreadPool 槽位泄漏
	request.request_thread_cleanup()
	
	# 收尾控制台流式段落，防止末尾输出未换行
	_close_console_segment()
	
	var error_message: String = request.get_error_message()
	if not error_message.is_empty():
		return {
			"error": error_message,
			"status_code": request.last_status_code,
			"retry_after": request.last_retry_after_s,
		}
	
	var result_msg: ChatMessage = assembler.take()
	if result_msg == null:
		return {
			"content": "",
			"reasoning_content": "",
			"tool_calls": [],
			"thinking_signature": "",
		}
	
	return {
		"content": result_msg.content,
		"reasoning_content": result_msg.reasoning_content,
		"tool_calls": result_msg.tool_calls.duplicate(true),
		"thinking_signature": String(result_msg.metadata.get(ChatMessage.META_THINKING_SIGNATURE, "")),
	}


# 随流式数据块实时打印控制台输出
# [param p_delta]: Provider 产出的协议无关增量
func _console_print_delta(p_delta: LLMStreamDelta) -> void:
	# 与 AIChatLogger 的 INFO 通道保持一致：关闭时不输出任何流式内容
	if not (AIChatLogger.current_flags & AIChatLogger.FLAG_INFO):
		return
	
	if not p_delta.reasoning_delta.is_empty():
		_open_console_segment(CONSOLE_SEGMENT_THINKING)
		_console_append(p_delta.reasoning_delta)
	
	if not p_delta.content_delta.is_empty():
		_open_console_segment(CONSOLE_SEGMENT_CONTENT)
		_console_append(p_delta.content_delta)
	
	# 工具调用开始即意味着本轮正文结束，及时刷新并收尾
	if not p_delta.tool_call_deltas.is_empty():
		_close_console_segment()


# 追加文本到控制台行缓冲
# [为什么按行输出] 编辑器 Output 面板按整行追加，printraw 的无换行输出不会形成行，
# 因此改为「整行即时输出 + 超长未换行强制折行」，兼顾实时性与可读性。
# [param p_text]: 待追加的流式增量文本
func _console_append(p_text: String) -> void:
	_console_line_buffer += p_text
	
	while true:
		var newline_pos: int = _console_line_buffer.find("\n")
		if newline_pos == -1:
			break
		var line: String = _console_line_buffer.substr(0, newline_pos)
		_console_line_buffer = _console_line_buffer.substr(newline_pos + 1)
		print(line.rstrip("\r"))
	
	if _console_line_buffer.length() >= CONSOLE_FLUSH_THRESHOLD:
		# 阈值折行时优先在空格处断开，避免把单词/数字从中间切开
		var break_pos: int = _console_line_buffer.rfind(" ")
		if break_pos <= 0:
			break_pos = _console_line_buffer.length()
		
		print(_console_line_buffer.substr(0, break_pos))
		_console_line_buffer = _console_line_buffer.substr(break_pos).strip_edges(true, false)


# 打开控制台输出段落：与当前段落不同时先收尾旧段落并打印标题
# [param p_segment]: CONSOLE_SEGMENT_* 之一
func _open_console_segment(p_segment: String) -> void:
	if _console_segment == p_segment:
		return
	
	_close_console_segment()
	_console_segment = p_segment
	
	if p_segment == CONSOLE_SEGMENT_THINKING:
		AIChatLogger.info("[Skill Agent Thinking]")
	else:
		AIChatLogger.info("[Skill Agent Output]")


# 收尾当前控制台输出段落（先刷出缓冲残留，再重置段落状态）
func _close_console_segment() -> void:
	if not _console_line_buffer.is_empty():
		print(_console_line_buffer)
		_console_line_buffer = ""
	
	if _console_segment.is_empty():
		return
	
	_console_segment = ""


# 加载 Skill Agent 自己的工具集
func _load_isolated_tools() -> void:
	_skill_agent_tools.clear()
	if REPORT_TASK_TOOL_SCRIPT:
		var inst: AiTool = REPORT_TASK_TOOL_SCRIPT.new()
		_skill_agent_tools[inst.tool_name] = inst
	
	var skill_res: Resource = ToolRegistry.available_skills.get(skill_name)
	if skill_res and "tools" in skill_res:
		for t_path: String in skill_res.tools:
			if FileAccess.file_exists(t_path):
				var script: Resource = load(t_path)
				if script and script is GDScript:
					var inst: AiTool = script.new()
					if inst.has_method("execute"):
						_skill_agent_tools[inst.tool_name] = inst


# 获取工具定义
func _get_tool_definitions(p_requires_gemini_schema: bool) -> Array[Dictionary]:
	return ToolRegistry.build_tool_definitions(_skill_agent_tools, p_requires_gemini_schema)


# 释放自身（移出场景树并排队释放）
# [为什么不再扫描同名节点] 本方法可能在多个 Skill Agent 并发运行期间被调用：
# 扫描并 remove_child() 其他实例会把它们变成孤儿节点（不会自动释放），
# 且它们挂在树上的协程会因 get_tree() 变为 null 而中断，
# 导致 Main Agent 对应的 create_skill_agent 工具调用永远收不到返回。
func _remove_skill_agent() -> void:
	queue_free()


func _clean_reference() -> void:
	_close_console_segment()
	_skill_agent_tools.clear()
	if is_instance_valid(_history):
		_history = null
