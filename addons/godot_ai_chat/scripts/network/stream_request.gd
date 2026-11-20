extends RefCounted

# HTTP 流式请求处理类
#
# 负责底层的 HTTP 流式请求处理，支持 SSE 和 JSON List 协议，在后台线程中运行。
#
# [线程模型与职责边界]
# 1. 工作线程仅负责纯粹的 HTTP 字节接收与行/块切分（不含任何厂商协议字段逻辑），
#    切出的 Dictionary 通过 call_deferred 投递到主线程 _deliver_chunk_on_main_thread()；
# 2. 主线程入口统一调用 _provider.parse_stream_chunk() 产出 LLMStreamDelta，
#    依据 delta.has_meaningful_progress() 推进 TimeoutTracker，并发射 delta_received；
# 3. 终态由主线程 _is_settled 幂等守卫唯一裁决，彻底消除迟到信号串扰与心跳无限续命。


# --- Signals ---

# 当主线程解析出一个协议无关增量时触发（推荐使用）
signal delta_received(delta: LLMStreamDelta)
# 当接收到一个完整的原始 JSON 数据块时触发（向后兼容保留）
signal chunk_received(chunk_data: Dictionary)
# 请求正常结束时触发（与 failed 互斥，至多触发一次）
signal finished
# 请求失败或超时时触发（与 finished 互斥，至多触发一次）
signal failed(error_message: String)


# --- Constants ---

const URLHelper := preload("res://addons/godot_ai_chat/scripts/helper/url_helper.gd")
const Utf8Helper := preload("res://addons/godot_ai_chat/scripts/helper/utf8_helper.gd")

# 任务结束后的回收等待告警阈值（毫秒）
# 超过该时长仍未结束只打印一次告警，不做阻塞等待，也不放弃对该任务的回收
const CLEANUP_WARN_MSEC: int = 1000


# --- Public Vars ---

# 最近一次请求的 HTTP 状态码（0 表示未获得响应，如连接阶段失败）
# [用途] 供上层判断错误类型（如 429 限流可重试），避免解析错误消息字符串
var last_status_code: int = 0

# 服务端通过 Retry-After 头建议的等待秒数（-1 表示未提供或无法解析）
var last_retry_after_s: float = -1.0


# --- Private Vars ---

var _provider: BaseLLMProvider
var _url: String
var _headers: PackedStringArray
var _body_json: String
# [Optimization] Store raw dict to stringify in thread
var _body_dict: Dictionary

var _stop_flag: bool = false
var _stop_flag_lock: Mutex = Mutex.new()
var _task_id: int = -1

# 超时检测器
var _timeout_tracker: TimeoutTracker

# [主线程独占] 唯一终态幂等守卫与流状态跟踪
var _is_settled: bool = false
var _is_cancelled: bool = false
var _error_message: String = ""
var _has_received_any_meaningful_delta: bool = false
var _has_received_protocol_end: bool = false

# 双层缓冲机制：字节缓冲（工作线程独占）
var _incoming_byte_buffer: PackedByteArray = PackedByteArray()
# 双层缓冲机制：文本缓冲（工作线程独占）
var _incoming_text_buffer: String = ""
# SSE 状态跟踪：当前正在处理的事件类型（工作线程独占）
var _current_sse_event: String = ""
# 传输层是否观察到流结束符（SSE 的 [DONE] 或 JSON_LIST 的闭合 ']'）（工作线程写入）
var _worker_saw_transport_eof_marker: bool = false

# 线程池任务回收状态
var _cleanup_request_msec: int = 0
var _cleanup_warned: bool = false
var _cleanup_scheduled: bool = false


# --- Built-in Functions ---

func _init(p_provider: BaseLLMProvider, p_url: String, p_headers: PackedStringArray, p_body_dict: Dictionary, p_timeout_tracker: TimeoutTracker = null) -> void:
	_provider = p_provider
	_url = p_url
	_headers = p_headers
	
	# [Optimization] Do NOT stringify here (Main Thread), just store the reference.
	_body_dict = p_body_dict
	# 使用传入的 TimeoutTracker，或创建默认
	_timeout_tracker = p_timeout_tracker if p_timeout_tracker else TimeoutTracker.from_network_timeout(180)


# --- Public Functions ---

# 开始执行流式请求（在线程池中运行）
func start() -> void:
	_stop_flag = false
	_is_settled = false
	_is_cancelled = false
	_error_message = ""
	_has_received_any_meaningful_delta = false
	_has_received_protocol_end = false
	_worker_saw_transport_eof_marker = false
	last_status_code = 0
	last_retry_after_s = -1.0
	
	_timeout_tracker.start_main_thread_watchdog()
	_task_id = WorkerThreadPool.add_task(self._thread_task, false, "Godot AI Chat Stream Request")
	AIChatLogger.debug("StreamRequest: Task ID %d started" % _task_id)


# 请求取消当前请求（主线程调用）
# 立即锁定唯一终态并置位停止标志，主线程等待循环可在当前帧/下一帧立即退出，
# 后台线程在下一个轮询周期（约 10ms）自行关闭连接并退出，迟到的 call_deferred 会被 _is_settled 拦截。
func cancel() -> void:
	_is_cancelled = true
	_is_settled = true
	if _error_message.is_empty():
		_error_message = "Cancelled by User"
	
	_stop_flag_lock.lock()
	_stop_flag = true
	_stop_flag_lock.unlock()


# 主线程每帧调用的看门狗检查
# 若业务层长时间无实质增量（即使网关仍在发心跳包）或总时长超限，主线程主动终止请求并发射 failed
func poll_watchdog() -> void:
	if _is_settled:
		return
	
	var timeout_reason: String = _timeout_tracker.check_main_thread_watchdog()
	if not timeout_reason.is_empty():
		abort_with_error(timeout_reason)


# 主线程主动以错误终态中止当前请求
func abort_with_error(p_error_msg: String) -> void:
	if _is_settled:
		return
	
	_stop_flag_lock.lock()
	_stop_flag = true
	_stop_flag_lock.unlock()
	
	_settle_failure_on_main_thread(p_error_msg)


# 当前请求是否已进入唯一终态（完成 / 失败 / 超时 / 已取消）
func is_settled() -> bool:
	return _is_settled


# 当前请求是否被用户取消
func is_cancelled() -> bool:
	return _is_cancelled


# 获取终态错误信息（成功时为空字符串）
func get_error_message() -> String:
	return _error_message


# 请求回收线程池任务槽位（非阻塞）
# 必须在任务结束（finished / failed 信号）或 cancel() 之后调用。
# 本方法不会阻塞调用线程：它先检查任务是否已结束，未结束则推迟到后续帧继续检查。
func request_thread_cleanup() -> void:
	if _task_id < 0:
		return
	
	# 仅在首次请求回收时记录起始时间：
	# 重复调用（如 cancel() 后再由请求结束路径调用一次）不应重置告警窗口
	if _cleanup_request_msec == 0:
		_cleanup_request_msec = Time.get_ticks_msec()
	
	_poll_thread_cleanup()


# --- Private Functions ---

# [主线程] 接收工作线程投递的原始 JSON 数据块，转换为 LLMStreamDelta 并按实际业务产出续期超时
func _deliver_chunk_on_main_thread(p_json: Dictionary) -> void:
	if _is_settled:
		return
	
	# 告知主线程已收到服务端响应数据（即便首个块是 message_start 等元数据，也续期一次首包等待）
	if _provider != null:
		var delta: LLMStreamDelta = _provider.parse_stream_chunk(p_json)
		if delta.is_stream_finished:
			_has_received_protocol_end = true
		
		if delta.has_meaningful_progress():
			_has_received_any_meaningful_delta = true
			_timeout_tracker.mark_progress()
		
		delta_received.emit(delta)
	
	chunk_received.emit(p_json)


# [主线程] 处理工作线程的流自然结束汇报，校验流是否完整闭合
func _on_worker_stream_eof_main_thread(p_saw_transport_eof: bool) -> void:
	if _is_settled:
		return
	
	var is_complete: bool = p_saw_transport_eof or _has_received_protocol_end
	if not _has_received_any_meaningful_delta:
		_settle_failure_on_main_thread("Stream closed by remote host before any model output was received.")
		return
	
	if not is_complete:
		_settle_failure_on_main_thread("Stream interrupted: Connection closed by remote host before generation finished.")
		return
	
	_is_settled = true
	finished.emit()


# [主线程] 锁定失败终态并发射 failed 信号（幂等，至多生效一次）
func _settle_failure_on_main_thread(p_msg: String) -> void:
	if _is_settled:
		return
	_is_settled = true
	_error_message = p_msg
	failed.emit(p_msg)


# 检查任务是否已结束；已结束则立即回收（此处的等待调用不会阻塞）
# 未结束则安排到下一帧继续检查
func _poll_thread_cleanup() -> void:
	if _task_id < 0:
		return
	
	if not WorkerThreadPool.is_task_completed(_task_id):
		var elapsed_msec: int = Time.get_ticks_msec() - _cleanup_request_msec
		if not _cleanup_warned and elapsed_msec >= CLEANUP_WARN_MSEC:
			_cleanup_warned = true
			AIChatLogger.warn("StreamRequest: task %d still running after %d ms; cleanup deferred to keep the editor responsive." % [_task_id, elapsed_msec])
		_schedule_cleanup_poll()
		return
	
	# is_task_completed() 已确认为 true，此调用会立即返回
	WorkerThreadPool.wait_for_task_completion(_task_id)
	_task_id = -1


# 在下一帧再次检查任务状态
# [为什么必须用 lambda 而不是普通方法 Callable]
# 标准方法 Callable 只保存 ObjectID，不会为 RefCounted 增加引用；
# 而 request_chat_async() 返回后，本对象可能已无其它强引用（current_stream_request 已被清空），
# 若此时后台任务尚未结束，实例会被提前释放 —— 工作线程随即访问已释放内存，
# 且任务槽位永远等不到 wait_for_task_completion()。
# GDScriptLambdaSelfCallable 内部持有 Ref<RefCounted>，能在整个轮询期间可靠地持有本实例。
func _schedule_cleanup_poll() -> void:
	if _cleanup_scheduled:
		return
	_cleanup_scheduled = true
	
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		# 没有主循环可挂帧回调：此时宁可同步等待一次，也不放弃任务槽位回收
		AIChatLogger.warn("StreamRequest: no SceneTree available; waiting for task %d synchronously." % _task_id)
		WorkerThreadPool.wait_for_task_completion(_task_id)
		_task_id = -1
		_cleanup_scheduled = false
		return
	
	tree.process_frame.connect(func() -> void: _on_cleanup_frame(), CONNECT_ONE_SHOT)


# process_frame 回调：归还调度标记并继续轮询
func _on_cleanup_frame() -> void:
	_cleanup_scheduled = false
	_poll_thread_cleanup()


# 线程任务主循环
func _thread_task() -> void:
	var t_begin: int = Time.get_ticks_msec()
	_body_json = ToolBox.stringify_json_safe(_body_dict)
	var t_serialized: int = Time.get_ticks_msec()
	AIChatLogger.debug("StreamRequest: body=%.2f MB, serialize=%d ms" % [_body_json.length() / 1048576.0, t_serialized - t_begin])
	
	# 预处理不计入网络超时预算
	_timeout_tracker.restart_phase_timer()
	
	var client: HTTPClient = HTTPClient.new()
	var err: Error = OK
	
	# 1. 解析 URL
	var url_parts: Dictionary = URLHelper.parse_url(_url)
	var protocol: String = String(url_parts.protocol)
	var host: String = String(url_parts.host)
	var port: int = int(url_parts.port)
	var path: String = String(url_parts.path)
	
	# 2. 连接服务器
	var tls_opts: TLSOptions = TLSOptions.client() if protocol == "https" else null
	err = client.connect_to_host(host, port, tls_opts)
	if err != OK:
		_emit_failure("Connection failed: %s" % error_string(err))
		client.close()
		return
	
	# 等待连接
	while client.get_status() == HTTPClient.STATUS_CONNECTING or client.get_status() == HTTPClient.STATUS_RESOLVING:
		client.poll()
		if _should_stop():
			client.close()
			return
		
		if _timeout_tracker.check().timed_out:
			_emit_failure("Connection timeout: Could not connect within %d seconds" % [_timeout_tracker.get_current_timeout_ms() / 1000])
			client.close()
			return
		
		OS.delay_msec(10)
	
	AIChatLogger.debug("StreamRequest: connect phase finished in %d ms, status=%d" % [Time.get_ticks_msec() - t_serialized, client.get_status()])
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		_emit_failure("Could not connect. Status: %d" % client.get_status())
		client.close()
		return
	
	# 3. 发送请求
	err = client.request(HTTPClient.METHOD_POST, path, _headers, _body_json)
	if err != OK:
		_emit_failure("Request sending failed: %s" % error_string(err))
		client.close()
		return
	
	# 4. 等待响应头
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		if _should_stop():
			client.close()
			return
		
		if _timeout_tracker.check().timed_out:
			_emit_failure("Request timeout: No response headers received within %d seconds" % [_timeout_tracker.get_current_timeout_ms() / 1000])
			client.close()
			return
		
		OS.delay_msec(10)
	
	if not client.has_response():
		_emit_failure("No response from server.")
		client.close()
		return
	
	var response_code: int = client.get_response_code()
	last_status_code = response_code
	
	if response_code != 200:
		last_retry_after_s = _parse_retry_after(client)
		var error_body: PackedByteArray = PackedByteArray()
		
		while client.get_status() == HTTPClient.STATUS_BODY:
			# [Fix] 错误体读取也响应取消：防止服务器挂起连接时无限忙等，
			# 导致 cancel 后回收任务时阻塞主线程（编辑器卡死）
			if _should_stop():
				client.close()
				return
			client.poll()
			if client.get_status() != HTTPClient.STATUS_BODY:
				break
			var error_chunk: PackedByteArray = client.read_response_body_chunk()
			if error_chunk.size() > 0:
				error_body.append_array(error_chunk)
			# 防御：错误体读取挂起时超时退出
			if _timeout_tracker.check().timed_out:
				_emit_failure("HTTP error body read timeout")
				client.close()
				return
			OS.delay_msec(10)
		
		var error_text: String = error_body.get_string_from_utf8()
		
		var json_err: Variant = null
		if error_text.strip_edges().begins_with("{"):
			json_err = JSON.parse_string(error_text)
		
		if json_err and json_err is Dictionary and json_err.has("error"):
			var err_msg: String = error_text
			if json_err.error is Dictionary:
				err_msg = String(json_err.error.get("message", error_text))
			else:
				err_msg = str(json_err.error)
			_emit_failure("API Error (%d): %s" % [response_code, err_msg])
		else:
			_emit_failure("HTTP Error %d: %s" % [response_code, error_text])
		
		client.close()
		return
	
	# 5. 流式读取循环（流内业务进展超时由主线程 poll_watchdog() 统一裁决并置位 _stop_flag）
	var parser_type: BaseLLMProvider.StreamParserType = _provider.get_stream_parser_type()
	
	while client.get_status() == HTTPClient.STATUS_BODY:
		if _should_stop():
			client.close()
			return
		
		client.poll()
		
		var current_status: HTTPClient.Status = client.get_status()
		var chunk: PackedByteArray = client.read_response_body_chunk()
		
		if chunk.size() > 0:
			_incoming_byte_buffer.append_array(chunk)
			
			if Utf8Helper.incomplete_tail_bytes(_incoming_byte_buffer) == 0:
				var new_text: String = _incoming_byte_buffer.get_string_from_utf8()
				_incoming_byte_buffer.clear()
				_incoming_text_buffer += new_text
				
				if parser_type == BaseLLMProvider.StreamParserType.SSE or parser_type == BaseLLMProvider.StreamParserType.LOCAL_SSE:
					_process_sse_buffer()
				elif parser_type == BaseLLMProvider.StreamParserType.JSON_LIST:
					_process_json_list_buffer()
		
		if current_status != HTTPClient.STATUS_BODY:
			break
		
		OS.delay_msec(10)
	
	if _should_stop():
		client.close()
		return
	
	# 处理流结束时可能残留在文本缓冲区的最后一行（部分服务端在最后一个事件后不补换行即关闭流）
	if not _incoming_text_buffer.strip_edges().is_empty():
		if parser_type == BaseLLMProvider.StreamParserType.SSE or parser_type == BaseLLMProvider.StreamParserType.LOCAL_SSE:
			_incoming_text_buffer += "\n"
			_process_sse_buffer()
		elif parser_type == BaseLLMProvider.StreamParserType.JSON_LIST:
			_process_json_list_buffer()
	
	var end_status: HTTPClient.Status = client.get_status()
	client.close()
	
	if end_status in [
		HTTPClient.STATUS_CANT_CONNECT,
		HTTPClient.STATUS_CANT_RESOLVE,
		HTTPClient.STATUS_CONNECTION_ERROR,
		HTTPClient.STATUS_TLS_HANDSHAKE_ERROR
	]:
		_emit_failure("Stream connection error (HTTPClient status: %d)." % end_status)
		return
	
	# 交由主线程排在所有已投递的 _deliver_chunk_on_main_thread 之后统一校验流是否完整结束
	_on_worker_stream_eof_main_thread.call_deferred(_worker_saw_transport_eof_marker)


# 处理 SSE 协议缓冲区
func _process_sse_buffer() -> void:
	while true:
		var newline_pos: int = _incoming_text_buffer.find("\n")
		if newline_pos == -1:
			break
		
		var line: String = _incoming_text_buffer.substr(0, newline_pos).strip_edges()
		_incoming_text_buffer = _incoming_text_buffer.substr(newline_pos + 1)
		
		if line.is_empty():
			continue
		
		# 捕获 Event 类型
		if line.begins_with("event:"):
			_current_sse_event = line.substr(6).strip_edges()
		
		# 处理 Data 内容
		elif line.begins_with("data:"):
			var json_raw: String = line.substr(5).strip_edges()
			
			if json_raw == "[DONE]":
				_worker_saw_transport_eof_marker = true
				continue
			if json_raw.is_empty():
				continue
			
			var json_val: Variant = JSON.parse_string(json_raw)
			if json_val is Dictionary:
				var d: Dictionary = json_val
				if not _current_sse_event.is_empty():
					d["_event_type"] = _current_sse_event
				_emit_chunk_data(d)
			else:
				AIChatLogger.warn("StreamRequest: Failed to parse SSE JSON chunk. Raw: " + json_raw)


# 处理 JSON List 协议缓冲区 (Gemini)
func _process_json_list_buffer() -> void:
	var search_offset: int = 0
	while true:
		var open_brace: int = _incoming_text_buffer.find("{", search_offset)
		if open_brace == -1:
			var stripped: String = _incoming_text_buffer.strip_edges()
			if stripped.ends_with("]"):
				_worker_saw_transport_eof_marker = true
			if stripped == "]" or stripped == "," or stripped.is_empty():
				_incoming_text_buffer = ""
			break
		
		if open_brace > 0:
			_incoming_text_buffer = _incoming_text_buffer.substr(open_brace)
			open_brace = 0
		
		var brace_level: int = 0
		var close_brace: int = -1
		var in_string: bool = false
		var escape: bool = false
		
		for i in range(open_brace, _incoming_text_buffer.length()):
			var character: String = _incoming_text_buffer[i]
			if escape:
				escape = false
				continue
			if character == "\\":
				escape = true
				continue
			if character == '"':
				in_string = not in_string
				continue
			if not in_string:
				if character == "{":
					brace_level += 1
				elif character == "}":
					brace_level -= 1
					if brace_level == 0:
						close_brace = i
						break
		
		if close_brace != -1:
			var json_str: String = _incoming_text_buffer.substr(open_brace, close_brace - open_brace + 1)
			var json_val: Variant = JSON.parse_string(json_str)
			if json_val is Dictionary:
				_emit_chunk_data(json_val)
			
			search_offset = close_brace + 1
			_incoming_text_buffer = _incoming_text_buffer.substr(search_offset)
			search_offset = 0
		else:
			break


# 投递 JSON 数据块到主线程（必转发，由主线程解析 LLMStreamDelta 后按内容决定是否续期超时）
func _emit_chunk_data(p_json: Dictionary) -> void:
	_deliver_chunk_on_main_thread.call_deferred(p_json)


# 延迟投递失败终态到主线程
func _emit_failure(p_msg: String) -> void:
	_settle_failure_on_main_thread.call_deferred(p_msg)


# 线程安全地检查是否应该停止
func _should_stop() -> bool:
	_stop_flag_lock.lock()
	var result: bool = _stop_flag
	_stop_flag_lock.unlock()
	return result


# 解析服务端 Retry-After 头
# [param p_client]: 已完成响应头的 HTTPClient
# [return]: 建议等待秒数；未提供或无法解析时返回 -1
func _parse_retry_after(p_client: HTTPClient) -> float:
	for header: String in p_client.get_response_headers():
		if not header.to_lower().begins_with("retry-after:"):
			continue
		var value: String = header.substr(header.find(":") + 1).strip_edges()
		if value.is_valid_float():
			return maxf(value.to_float(), 0.0)
		return -1.0
	return -1.0
