@tool
class_name StreamRequest
extends RefCounted

## HTTP 流式请求处理类
##
## 负责底层的 HTTP 流式请求处理，支持 SSE 和 JSON List 协议，在后台线程中运行。
##
## [线程模型] 网络 IO 全部在 WorkerThreadPool 任务中完成；本类对外暴露的信号
## 一律通过 call_deferred 投递回主线程，因此消费端无需关心线程安全问题。
##
## [资源回收] WorkerThreadPool 要求每个任务最终都被 wait_for_task_completion() 等待一次。
## 直接等待会阻塞主线程，故本类采用「逐帧轮询 is_task_completed()，确认完成后再等待」的策略：
## 轮询本身无阻塞，等待时任务已结束因而立即返回。


# --- Signals ---

## 当接收到一个完整的 JSON 数据块时触发
signal chunk_received(chunk_data: Dictionary)
## 请求正常结束时触发
signal finished
## 请求失败时触发
signal failed(error_message: String)


# --- Constants ---

## 任务结束后的回收等待告警阈值（毫秒）
## 超过该时长仍未结束只打印一次告警，不做阻塞等待，也不放弃对该任务的回收
const CLEANUP_WARN_MSEC: int = 1000


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
var _has_emitted_first_chunk: bool = false

# 双层缓冲机制：字节缓冲
var _incoming_byte_buffer: PackedByteArray = PackedByteArray()
# 双层缓冲机制：文本缓冲
var _incoming_text_buffer: String = ""
# SSE 状态跟踪：当前正在处理的事件类型
var _current_sse_event: String = ""

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

## 开始执行流式请求（在线程池中运行）
func start() -> void:
	_stop_flag = false
	_has_emitted_first_chunk = false
	_task_id = WorkerThreadPool.add_task(self._thread_task, false, "Godot AI Chat Stream Request")
	AIChatLogger.debug("StreamRequest: Task ID %d started" % _task_id)


## 请求取消当前请求
## 仅置位停止标志并唤醒工作线程，不在调用线程做任何等待。
## 工作线程会在下一个轮询周期（约 10ms）自行关闭连接并退出。
func cancel() -> void:
	# 使用 Mutex 保护跨线程访问
	_stop_flag_lock.lock()
	_stop_flag = true
	_stop_flag_lock.unlock()
	
	# 不再跨线程调用 _http_client.close()
	# 由工作线程在下一轮 poll 检测到 _stop_flag 后自行 close，避免数据竞争


## 请求回收线程池任务槽位（非阻塞）
## 必须在任务结束（finished / failed 信号）或 cancel() 之后调用。
## 本方法不会阻塞调用线程：它先检查任务是否已结束，未结束则推迟到后续帧继续检查。
func request_thread_cleanup() -> void:
	if _task_id < 0:
		return
	
	# 仅在首次请求回收时记录起始时间：
	# 重复调用（如 cancel() 后再由请求结束路径调用一次）不应重置告警窗口
	if _cleanup_request_msec == 0:
		_cleanup_request_msec = Time.get_ticks_msec()
	
	_poll_thread_cleanup()


# --- Private Functions ---

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
func _schedule_cleanup_poll() -> void:
	if _cleanup_scheduled:
		return
	_cleanup_scheduled = true
	
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		_task_id = -1
		_cleanup_scheduled = false
		return
	
	tree.process_frame.connect(_on_cleanup_frame, CONNECT_ONE_SHOT)


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
	
	# 等待连接（WAITING_FIRST_TOKEN 阶段）
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
	
	# 4. 等待响应（仍在 WAITING_FIRST_TOKEN 阶段）
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		if _should_stop():
			client.close()
			return
		
		if _timeout_tracker.check().timed_out:
			_emit_failure("Request timeout: No response received within %d seconds" % [_timeout_tracker.get_current_timeout_ms() / 1000])
			client.close()
			return
		
		OS.delay_msec(10)
	
	if not client.has_response():
		_emit_failure("No response from server.")
		client.close()
		return
	
	var response_code: int = client.get_response_code()
	
	if response_code != 200:
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
		
		#var json_err = JSON.parse_string(error_text)
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
	
	# 5. 流式读取循环
	var parser_type: BaseLLMProvider.StreamParserType = _provider.get_stream_parser_type()
	
	while client.get_status() == HTTPClient.STATUS_BODY:
		if _should_stop():
			client.close()
			return
		
		client.poll()
		
		if client.get_status() != HTTPClient.STATUS_BODY:
			break
		
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
		else:
			# 没有收到数据，检查是否超时
			if _timeout_tracker.check().timed_out:
				_emit_failure("Connection timeout: No data received for %d seconds" % [_timeout_tracker.get_current_timeout_ms() / 1000])
				client.close()
				return
		
		OS.delay_msec(10)
	
	client.close()
	finished.emit.call_deferred()


# 处理 SSE 协议缓冲区
func _process_sse_buffer() -> void:
	while true:
		var newline_pos: int = _incoming_text_buffer.find("\n")
		if newline_pos == -1:
			break
		
		var line: String = _incoming_text_buffer.substr(0, newline_pos).strip_edges()
		_incoming_text_buffer = _incoming_text_buffer.substr(newline_pos + 1)
		
		if line.is_empty():
			# 空行通常意味着一个 Event 块的结束，重置 event 状态
			# 但有些实现可能不发空行，直接发下一个 event，所以这里只做清理
			# _current_sse_event = ""
			# 注意：Anthropic 的 event 和 data 是紧挨着的，不一定有空行分隔
			continue
		
		# 捕获 Event 类型
		if line.begins_with("event:"):
			_current_sse_event = line.substr(6).strip_edges()
		
		# 处理 Data 内容
		elif line.begins_with("data:"):
			var json_raw: String = line.substr(5).strip_edges()
			
			if json_raw == "[DONE]" or json_raw.is_empty():
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


# 延迟发射 JSON 数据信号
func _emit_chunk_data(p_json: Dictionary) -> void:
	if not _has_emitted_first_chunk:
		_has_emitted_first_chunk = true
		_timeout_tracker.mark_first_token_received()
	else:
		_timeout_tracker.mark_data_received()
	chunk_received.emit.call_deferred(p_json)


# 延迟发射失败信号
func _emit_failure(p_msg: String) -> void:
	failed.emit.call_deferred(p_msg)


# 线程安全地检查是否应该停止
func _should_stop() -> bool:
	_stop_flag_lock.lock()
	var result: bool = _stop_flag
	_stop_flag_lock.unlock()
	return result
