@tool
extends Node
class_name ChatStreamedHTTPRequest


# 当从流中成功解析出一个新的文本数据块时发出。
signal new_stream_chunk_received(chunk_text: String)
# 当数据流正常、完整地结束时发出。
signal stream_request_completed
signal stream_usage_data_received(usage_data: Dictionary)
# 当用户手动停止接受流式数据流时发出
signal stream_request_canceled
# 当请求过程中发生任何错误（如连接失败、URL无效、解析错误）时发出。
signal stream_request_failed(error_message: String)

# 指向后台网络线程的引用。
var _thread: Thread = null
# 用于从主线程安全地通知后台线程停止的标志。
var _stop_thread_flag: bool = false
# 用于保护 `_stop_thread_flag` 变量的互斥锁，确保线程安全的读写访问。
var _mutex: Mutex = Mutex.new()
# 用于区分不同的线程任务，防止旧线程的回调影响新线程的状态。
var _current_thread_id: int = 0

var _last_usage_data_in_stream: Dictionary = {}


# 当此节点从场景树中移除时，Godot会自动调用此函数进行清理，确保后台线程被安全停止的关键。
func _exit_tree() -> void:
	thread_shutdown_and_wait()


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 发起一个新的流式HTTP请求。
func start_new_stream_request(_url: String, _headers: PackedStringArray, _body: String, _api_provider: String) -> void:
	_last_usage_data_in_stream.clear()
	
	# 如果上一个线程仍在运行，先安全地停止它。
	if is_instance_valid(_thread):
		_mutex.lock()
		_stop_thread_flag = true
		_mutex.unlock()
		_thread.wait_to_finish()
		print("[MAIN_THREAD] Previous thread finished before new request.")
	
	# 重置停止标志，为新线程做准备。
	_mutex.lock()
	_stop_thread_flag = false
	_mutex.unlock()
	
	# 创建并启动一个新的线程来处理网络请求。
	_thread = Thread.new()
	_current_thread_id += 1 # 递增并使用新的线程ID
	var callable: Callable = Callable(self, "_thread_worker")
	_thread.start(callable.bind(_url, _headers, _body, _api_provider ,_current_thread_id))


# 请求停止当前的流式传输，但不会阻塞等待。
# 这用于UI上的“停止”按钮，可以立即返回，不会冻结界面。
func cancel_current_stream_request() -> void:
	if _thread != null and _thread.is_alive():
		_mutex.lock()
		_stop_thread_flag = true
		_mutex.unlock()
		print("[ChatStreamedHTTPRequest] Stop request issued to thread.")


# 安全地关闭并等待后台线程结束。
# 它会阻塞调用它的线程（通常是主线程），直到后台线程完全退出。
func thread_shutdown_and_wait() -> void:
	if _thread != null and _thread.is_alive():
		_mutex.lock()
		_stop_thread_flag = true
		_mutex.unlock()
		_thread.wait_to_finish()
		await get_tree().create_timer(0.5).timeout
		print("[ChatStreamedHTTPRequest] Thread shut down gracefully.")


#==============================================================================
# ## 内部函数 ##
#==============================================================================

# 这是在后台线程中执行的主函数。所有耗时的网络操作都在这里进行。
func _thread_worker(_url_string: String, _headers: PackedStringArray, _body_json: String, _api_provider: String, _thread_id: int) -> void:
	print("[THREAD] Worker started. URL: ", _url_string)
	var http_client := HTTPClient.new()
	
	# 获取全局超时设置
	var timeout_sec: float = ToolBox.get_plugin_settings().network_timeout
	var timeout_msec: int = int(timeout_sec * 1000)
	
	# 1. 解析URL
	var parsed_url_result: Dictionary = _parse_url(_url_string)
	if not parsed_url_result.success:
		Callable(self, "_on_stream_request_failed_from_thread").call_deferred(parsed_url_result.error, _thread_id)
		return
	
	# 2. 建立连接 (增加超时检测)
	if not _establish_connection(http_client, parsed_url_result, _thread_id, timeout_msec):
		return
	
	# 3. 发送请求
	if not _send_request(http_client, parsed_url_result.path, _headers, _body_json, _thread_id): return
	
	# 4. 等待响应头 (增加超时检测)
	if not _wait_and_verify_response(http_client, _thread_id, timeout_msec):
		return
	
	# 5. 处理流式响应 (保持现有的数据块超时检测)
	_process_response_stream(http_client, _api_provider, _thread_id, timeout_msec)
	
	# 线程结束逻辑...
	_mutex.lock()
	var was_stopped: bool = _stop_thread_flag
	_mutex.unlock()
	
	if not was_stopped:
		Callable(self, "_on_stream_request_completed_from_thread").call_deferred(_thread_id)
	else:
		Callable(self, "_on_stream_request_canceled_from_thread").call_deferred(_thread_id)


# 等待响应头并检查状态码
func _wait_and_verify_response(_http_client: HTTPClient, _thread_id: int, _timeout_msec: int) -> bool:
	var start_time = Time.get_ticks_msec()
	while _http_client.get_status() == HTTPClient.STATUS_REQUESTING:
		# 超时检查
		if Time.get_ticks_msec() - start_time > _timeout_msec:
			Callable(self, "_on_stream_request_failed_from_thread").call_deferred("Request timed out while waiting for response.", _thread_id)
			return false
		
		_mutex.lock()
		if _stop_thread_flag: _mutex.unlock(); return false
		_mutex.unlock()
		
		_http_client.poll()
		OS.delay_msec(10)
	
	if not _http_client.has_response():
		Callable(self, "_on_stream_request_failed_from_thread").call_deferred("No response received from server.", _thread_id)
		return false
	
	var response_code: int = _http_client.get_response_code()
	if response_code != 200:
		var body_chunk: PackedByteArray = _http_client.read_response_body_chunk()
		var error_msg: String = "HTTP %d: %s" % [response_code, body_chunk.get_string_from_utf8()]
		Callable(self, "_on_stream_request_failed_from_thread").call_deferred(error_msg, _thread_id)
		return false
	
	return true


func _parse_url(_url_string: String) -> Dictionary:
	var result: Dictionary = {"success": true, "error": "", "host": "", "port": -1, "path": "/", "use_ssl": false}
	var scheme_end: int = _url_string.find("://")
	
	if scheme_end == -1:
		result.success = false; result.error = "Invalid URL: Missing '://'."
		return result
	
	var scheme: String = _url_string.substr(0, scheme_end)
	if scheme == "https":
		result.use_ssl = true
		result.port = 443
	elif scheme == "http":
		result.use_ssl = false
		result.port = 80
	else:
		result.success = false
		result.error = "Invalid URL scheme: '%s'." % scheme
		return result
	
	var host_and_port: String
	var url_no_scheme: String = _url_string.substr(scheme_end + 3)
	
	var path_start: int = url_no_scheme.find("/")
	if path_start == -1:
		host_and_port = url_no_scheme; result.path = "/"
	else:
		host_and_port = url_no_scheme.substr(0, path_start); result.path = url_no_scheme.substr(path_start)
	
	var port_start: int = host_and_port.find(":")
	if port_start != -1:
		result.host = host_and_port.substr(0, port_start)
		var port_str: String = host_and_port.substr(port_start + 1)
		if port_str.is_valid_int():
			result.port = port_str.to_int()
		else:
			result.success = false
			result.error = "Invalid port in URL: '%s'." % port_str
			return result
	
	else: result.host = host_and_port
	return result


func _establish_connection(_http_client: HTTPClient, _parsed_url: Dictionary, _thread_id: int, _timeout_msec: int) -> bool:
	var tls_options: TLSOptions = TLSOptions.client() if _parsed_url.use_ssl else null
	var err: Error = _http_client.connect_to_host(_parsed_url.host, _parsed_url.port, tls_options)
	if err != OK:
		Callable(self, "_on_stream_request_failed_from_thread").call_deferred("HTTPClient: Failed to initiate connection.", _thread_id)
		return false
	
	var start_time = Time.get_ticks_msec()
	while _http_client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		# 超时检查
		if Time.get_ticks_msec() - start_time > _timeout_msec:
			Callable(self, "_on_stream_request_failed_from_thread").call_deferred("Connection timed out.", _thread_id)
			return false
		
		_mutex.lock()
		if _stop_thread_flag: _mutex.unlock(); return false
		_mutex.unlock()
		
		_http_client.poll()
		OS.delay_msec(10)
	
	if _http_client.get_status() != HTTPClient.STATUS_CONNECTED:
		Callable(self, "_on_stream_request_failed_from_thread").call_deferred("Connection failed. Status: %d" % _http_client.get_status(), _thread_id)
		return false
	
	return true


func _send_request(_http_client: HTTPClient, _path: String, _headers: PackedStringArray, _body: String, _thread_id: int) -> bool:
	var err: Error = _http_client.request(HTTPClient.METHOD_POST, _path, _headers, _body)
	if err != OK:
		var error_msg = "HTTPClient: Request failed. Error: %s" % err
		print("[THREAD][ERROR] ", error_msg)
		Callable(self, "_on_stream_request_failed_from_thread").call_deferred(error_msg, _thread_id)
		return false
	return true


func _process_response_stream(_http_client: HTTPClient, _api_provider: String, _thread_id: int, _stream_read_timeout_msec: int) -> void:
	var response_buffer: PackedByteArray = PackedByteArray()
	var json_parser: JSON = JSON.new()
	var stream_finished: bool = false
	var last_data_received_time: int = Time.get_ticks_msec()
	
	print("[THREAD] Entering response stream loop.")
	while not stream_finished:
		_mutex.lock()
		if _stop_thread_flag: _mutex.unlock(); return
		_mutex.unlock()
		
		# 使用传入的参数进行超时检查
		if Time.get_ticks_msec() - last_data_received_time > _stream_read_timeout_msec:
			var error_msg: String = "Network stream timed out. No data received for %d seconds." % (_stream_read_timeout_msec / 1000)
			print("[THREAD][ERROR] ", error_msg)
			Callable(self, "_on_stream_request_failed_from_thread").call_deferred(error_msg, _thread_id)
			stream_finished = true
			break
		
		_http_client.poll()
		var status: HTTPClient.Status = _http_client.get_status()
		
		if status == HTTPClient.STATUS_BODY:
			var chunk = _http_client.read_response_body_chunk()
			if chunk.size() > 0:
				# 关键修复：在这里更新最后接收数据的时间
				last_data_received_time = Time.get_ticks_msec()
				response_buffer.append_array(chunk)
				var parse_result: Dictionary = _parse_buffer_and_get_remainder(response_buffer, json_parser, true, _api_provider, _thread_id)
				response_buffer = parse_result.remainder
				if parse_result.finished: stream_finished = true
		
		# 处理各种错误和连接中断状态
		elif status in [HTTPClient.STATUS_DISCONNECTED, HTTPClient.STATUS_CANT_RESOLVE, HTTPClient.STATUS_CANT_CONNECT, HTTPClient.STATUS_CONNECTION_ERROR, HTTPClient.STATUS_TLS_HANDSHAKE_ERROR]:
			var error_msg: String = "Network connection lost during stream. Status: %s" % status
			print("[THREAD][ERROR] ", error_msg)
			Callable(self, "_on_stream_request_failed_from_thread").call_deferred(error_msg, _thread_id)
			stream_finished = true # 强制退出循环
			break
		
		elif status != HTTPClient.STATUS_REQUESTING:
			_parse_buffer_and_get_remainder(response_buffer, json_parser, false, _api_provider, _thread_id)
			stream_finished = true
			break
		
		OS.delay_msec(10)
	print("[THREAD] Exited response stream loop. Final status: ", _http_client.get_status())


func _parse_buffer_and_get_remainder(_buffer: PackedByteArray, _json_parser: JSON, _is_streaming: bool, _api_provider: String, _thread_id: int) -> Dictionary:
	if _api_provider == "Google Gemini":
		return _parse_gemini_json_stream(_buffer, _json_parser, _api_provider, _thread_id)
	elif _api_provider == "OpenAI-Compatible" or _api_provider == "ZhipuAI":
		return _parse_sse_stream(_buffer, _json_parser, _is_streaming, _api_provider, _thread_id)
	else:
		return {}


func _parse_gemini_json_stream(_buffer: PackedByteArray, _json_parser: JSON, _api_provider: String, _thread_id: int) -> Dictionary:
	var text: String = _buffer.get_string_from_utf8()
	var last_processed_pos: int = 0
	var search_offset: int = 0
	
	while true:
		var object_start: int = text.find("{", search_offset)
		if object_start == -1:
			break
		
		var brace_level: int = 1
		var object_end: int = -1
		
		for i in range(object_start + 1, text.length()):
			var char = text[i]
			if char == '{':
				brace_level += 1
			elif char == '}':
				brace_level -= 1
			if brace_level == 0:
				object_end = i
				break
		
		if object_end != -1:
			var json_str: String = text.substr(object_start, object_end - object_start + 1)
			if _json_parser.parse(json_str) == OK:
				var json_data = _json_parser.get_data()
				if json_data is Dictionary:
					var chunk: String = AiServiceAdapter.parse_stream_chunk(_api_provider, json_data)
					if not chunk.is_empty():
						Callable(self, "_on_chunk_received_from_thread").call_deferred(chunk, _thread_id)
					
					var usage: Dictionary = AiServiceAdapter.parse_stream_usage_chunk(_api_provider, json_data)
					if not usage.is_empty():
						#Callable(self, "_on_usage_data_received_from_thread").call_deferred(usage, _thread_id)
						# 不再发送信号，而是更新缓存变量
						_last_usage_data_in_stream = usage
			
			last_processed_pos = object_end + 1
			search_offset = last_processed_pos
		else:
			break
	
	var processed_bytes: int = text.substr(0, last_processed_pos).to_utf8_buffer().size()
	var remaining_buffer: PackedByteArray = _buffer.slice(processed_bytes)
	return {"finished": false, "remainder": remaining_buffer}


func _parse_sse_stream(_buffer: PackedByteArray, _json_parser: JSON, _streaming: bool, _api_provider: String, _thread_id: int) -> Dictionary:
	var text: String = _buffer.get_string_from_utf8()
	var lines: PackedStringArray = text.split("\n", false)
	var lines_to_process: int = lines.size()
	
	if _streaming and not text.ends_with("\n"):
		lines_to_process -= 1
	if lines_to_process <= 0:
		return {"finished": false, "remainder": _buffer}
	
	var processed_bytes: int = 0
	var stream_should_end: bool = false
	
	for i in range(lines_to_process):
		var line_content = lines[i]
		processed_bytes += line_content.to_utf8_buffer().size() + 1 
		var line_result: Dictionary = _process_stream_line(line_content, _json_parser, _api_provider, _thread_id)
		
		if not line_result.chunk.is_empty():
			Callable(self, "_on_chunk_received_from_thread").call_deferred(line_result.chunk, _thread_id)
		if line_result.finished:
			stream_should_end = true
			break
	
	var remaining_buffer: PackedByteArray = _buffer.slice(processed_bytes)
	return {"finished": stream_should_end, "remainder": remaining_buffer}


func _process_stream_line(_line_content: String, _json_parser: JSON, _api_provider: String, _thread_id: int) -> Dictionary:
	var result: Dictionary = {"chunk": "", "finished": false}
	var stripped_line: String = _line_content.strip_edges()
	if not stripped_line.begins_with("data:"):
		return result
	
	var json_str: String = stripped_line.substr(5).strip_edges()
	if json_str == "[DONE]":
		print("[THREAD] [DONE] signal received.")
		result.finished = true
		return result
	
	if json_str.is_empty():
		return result
	if _json_parser.parse(json_str) != OK:
		return result
	
	var json_data = _json_parser.get_data()
	if json_data is Dictionary:
		result.chunk = AiServiceAdapter.parse_stream_chunk(_api_provider, json_data)
		
		var usage: Dictionary = AiServiceAdapter.parse_stream_usage_chunk(_api_provider, json_data)
		if not usage.is_empty():
			# 修改: 不再发送信号，而是更新缓存变量
			_last_usage_data_in_stream = usage
	
	return result


#==============================================================================
# ## 信号回调函数 ##
#==============================================================================

func _on_chunk_received_from_thread(_chunk_text: String, _received_thread_id: int) -> void:
	#print("[NETWORK CHUNK RECEIVED] Length: ", chunk_text.length(), " | Content: '", chunk_text.replace("\n", "\\n"), "'")
	# 只有当回调来自当前活动的线程时，才发出信号
	if not is_queued_for_deletion() and _received_thread_id == _current_thread_id:
		emit_signal("new_stream_chunk_received", _chunk_text)


func _on_stream_request_completed_from_thread(_finished_thread_id: int) -> void:
	if not is_queued_for_deletion() and _finished_thread_id == _current_thread_id:
		# 在流正常结束后，检查缓存中是否有最终的 usage 数据
		if not _last_usage_data_in_stream.is_empty():
			# 如果有，就在这里一次性地把它发射出去
			emit_signal("stream_usage_data_received", _last_usage_data_in_stream)
		
		print("[MAIN_THREAD] Stream ended. Cleaning up thread object.")
		emit_signal("stream_request_completed")
		# 清理已结束的线程对象
		if is_instance_valid(_thread) and not _thread.is_alive():
			_thread.wait_to_finish()
			_thread = null
			print("[MAIN_THREAD] Thread object cleaned up.")


func _on_stream_request_canceled_from_thread(_canceled_thread_id: int) -> void:
	if not is_queued_for_deletion() and _canceled_thread_id == _current_thread_id:
		if not _last_usage_data_in_stream.is_empty():
			emit_signal("stream_usage_data_received", _last_usage_data_in_stream)
		
		print("[MAIN_THREAD] Stream canceled by user. Cleaning up thread object.")
		emit_signal("stream_request_canceled")
		# 清理已结束的线程对象
		if is_instance_valid(_thread) and not _thread.is_alive():
			_thread.wait_to_finish()
			_thread = null
			print("[MAIN_THREAD] Thread object cleaned up after cancellation.")


func _on_stream_request_failed_from_thread(_error_message: String, _finished_thread_id: int) -> void:
	if not is_queued_for_deletion() and _finished_thread_id == _current_thread_id:
		if not _last_usage_data_in_stream.is_empty():
			emit_signal("stream_usage_data_received", _last_usage_data_in_stream)
		
		print("[MAIN_THREAD] Stream failed. Cleaning up thread object. Error: ", _error_message)
		emit_signal("stream_request_failed", _error_message)
		# 清理已结束的线程对象
		if is_instance_valid(_thread) and not _thread.is_alive():
			_thread.wait_to_finish()
			_thread = null
			print("[MAIN_THREAD] Thread object cleaned up after failure.")
