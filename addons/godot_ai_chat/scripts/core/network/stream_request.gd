@tool
class_name StreamRequest
extends RefCounted

## HTTP 流式请求处理类
##
## 负责底层的 HTTP 流式请求处理，支持 SSE 和 JSON List 协议，在后台线程中运行。

# --- Signals ---

## 当接收到一个完整的 JSON 数据块时触发
signal chunk_received(chunk_data: Dictionary)
## 当接收到 Usage 数据时触发
signal usage_received(usage: Dictionary)
## 请求正常结束时触发
signal finished
## 请求失败时触发
signal failed(error_message: String)

# --- Private Vars ---

var _provider: BaseLLMProvider
var _url: String
var _headers: PackedStringArray
var _body_json: String
# [Optimization] Store raw dict to stringify in thread
var _body_dict: Dictionary 

var _stop_flag: bool = false
var _task_id: int = -1

## 双层缓冲机制：字节缓冲
var _incoming_byte_buffer: PackedByteArray = PackedByteArray()
## 双层缓冲机制：文本缓冲
var _incoming_text_buffer: String = ""
## [新增] SSE 状态跟踪：当前正在处理的事件类型
var _current_sse_event: String = ""


# --- Built-in Functions ---

func _init(p_provider: BaseLLMProvider, p_url: String, p_headers: PackedStringArray, p_body_dict: Dictionary) -> void:
	_provider = p_provider
	_url = p_url
	_headers = p_headers
	# [Optimization] Do NOT stringify here (Main Thread), just store the reference.
	# _body_json = JSON.stringify(p_body_dict) 
	_body_dict = p_body_dict


# --- Public Functions ---

## 开始执行流式请求（在线程池中运行）
func start() -> void:
	_stop_flag = false
	_task_id = WorkerThreadPool.add_task(self._thread_task, false, "Godot AI Chat Stream Request")


## 取消当前请求
func cancel() -> void:
	_stop_flag = true


# --- Private Functions ---

## 线程任务主循环
func _thread_task() -> void:
	# [Optimization] Perform CPU-intensive JSON serialization in the worker thread
	_body_json = JSON.stringify(_body_dict)
	
	var client: HTTPClient = HTTPClient.new()
	var err: Error = OK
	
	# 1. 解析 URL
	var protocol_pos: int = _url.find("://")
	var protocol: String = _url.substr(0, protocol_pos)
	var rest: String = _url.substr(protocol_pos + 3)
	var host_end: int = rest.find("/")
	var host: String = rest.substr(0, host_end) if host_end != -1 else rest
	var path: String = rest.substr(host_end) if host_end != -1 else "/"
	var port: int = 443 if protocol == "https" else 80
	
	if ":" in host:
		var parts: PackedStringArray = host.split(":")
		host = parts[0]
		port = parts[1].to_int()
	
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
		if _stop_flag:
			client.close() 
			return
		OS.delay_msec(10)
	
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
	
	# 4. 等待响应
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		if _stop_flag:
			client.close() 
			return
		OS.delay_msec(10)
	
	if not client.has_response():
		_emit_failure("No response from server.")
		client.close() 
		return
	
	var response_code: int = client.get_response_code()
	
	if response_code != 200:
		# [调试关键] 捕获错误响应体
		var error_body: PackedByteArray = PackedByteArray()
		
		while client.get_status() == HTTPClient.STATUS_BODY:
			client.poll()
			if client.get_status() != HTTPClient.STATUS_BODY:
				break
			var chunk: PackedByteArray = client.read_response_body_chunk()
			if chunk.size() > 0:
				error_body.append_array(chunk)
		
		var error_text: String = error_body.get_string_from_utf8()
		
		# [调试输出] 打印完整的错误响应
		#print("🔴 HTTP Error ", response_code, " Response Body:")
		#print(error_text)
		#print("📋 Request URL: ", _url)
		#print("📤 Request Body: ", _body_json.left(500))  # 打印请求体前500字符
		
		# 尝试解析 JSON 错误
		var json_err = JSON.parse_string(error_text)
		if json_err and json_err is Dictionary and json_err.has("error"):
			var err_msg = json_err.error.get("message", error_text)
			_emit_failure("API Error (%d): %s" % [response_code, err_msg])
		else:
			_emit_failure("HTTP Error %d: %s" % [response_code, error_text])
		
		client.close() 
		return
	
	# 5. 流式读取循环
	var parser_type: BaseLLMProvider.StreamParserType = _provider.get_stream_parser_type()
	
	while client.get_status() == HTTPClient.STATUS_BODY:
		if _stop_flag:
			client.close() 
			return
		
		client.poll()
		
		if client.get_status() != HTTPClient.STATUS_BODY:
			break
		
		var chunk: PackedByteArray = client.read_response_body_chunk()
		
		if chunk.size() > 0:
			_incoming_byte_buffer.append_array(chunk)
			
			if _is_buffer_safe_for_utf8(_incoming_byte_buffer):
				var new_text: String = _incoming_byte_buffer.get_string_from_utf8()
				_incoming_byte_buffer.clear()
				_incoming_text_buffer += new_text
				
				if parser_type == BaseLLMProvider.StreamParserType.SSE or parser_type == BaseLLMProvider.StreamParserType.LOCAL_SSE:
					_process_sse_buffer()
				elif parser_type == BaseLLMProvider.StreamParserType.JSON_LIST:
					_process_json_list_buffer()
		
		OS.delay_msec(10)
	
	client.close() 
	finished.emit.call_deferred()


## 处理 SSE 协议缓冲区
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
		
		# 1. 捕获 Event 类型
		if line.begins_with("event:"):
			_current_sse_event = line.substr(6).strip_edges()
		
		# 2. 处理 Data 内容
		elif line.begins_with("data:"):
			var json_raw: String = line.substr(5).strip_edges()
			
			if json_raw == "[DONE]":
				continue
			
			if not json_raw.is_empty():
				var result: Dictionary = _try_parse_one_json(json_raw)
				if result.success:
					if result.data is Dictionary:
						#_emit_chunk_data(result.data)
						# [注入] 将 Event 类型注入到数据中，供上层 Provider 使用
						if not _current_sse_event.is_empty():
							result.data["_event_type"] = _current_sse_event
						_emit_chunk_data(result.data)
				else:
					var json_obj: JSON = JSON.new()
					var err: Error = json_obj.parse(json_raw)
					if err == OK:
						if json_obj.data is Dictionary:
							#_emit_chunk_data(json_obj.data)
							if not _current_sse_event.is_empty():
								json_obj.data["_event_type"] = _current_sse_event
							_emit_chunk_data(json_obj.data)
					else:
						#push_warning("StreamRequest: Failed to parse SSE JSON chunk. Raw: " + json_raw)
						# 只有当确实解析失败时才警告，忽略空的心跳包
						if json_raw != "[DONE]":
							push_warning("StreamRequest: Failed to parse SSE JSON chunk. Raw: " + json_raw)
	
	# 处理完 data 后，通常意味着这个 event/data 对结束了
	# 但为了安全起见，我们不立即清空 event，防止有多行 data 的情况（虽然我们不支持合并）
	# 在遇到下一个 event: 时会自动覆盖


## 处理 JSON List 协议缓冲区 (Gemini)
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
			var char: String = _incoming_text_buffer[i]
			if escape: 
				escape = false
				continue
			if char == "\\": 
				escape = true
				continue
			if char == '"': 
				in_string = not in_string
				continue
			if not in_string:
				if char == "{": 
					brace_level += 1
				elif char == "}":
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


## 延迟发射 JSON 数据信号
func _emit_chunk_data(p_json: Dictionary) -> void:
	chunk_received.emit.call_deferred(p_json)


## 延迟发射失败信号
func _emit_failure(p_msg: String) -> void:
	failed.emit.call_deferred(p_msg)


## 尝试从字符串开头解析一个完整的 JSON 对象
func _try_parse_one_json(p_s: String) -> Dictionary:
	if p_s.is_empty() or p_s[0] != "{":
		return { "success": false, "length": 0 }
	
	var balance: int = 0
	var in_string: bool = false
	var escaped: bool = false
	var length: int = 0
	
	for i in range(p_s.length()):
		var char: String = p_s[i]
		length += 1
		
		if escaped:
			escaped = false
			continue
		if char == "\\":
			escaped = true
			continue
		if char == '"':
			in_string = not in_string
			continue
		
		if not in_string:
			if char == '{':
				balance += 1
			elif char == '}':
				balance -= 1
				if balance == 0:
					var candidate: String = p_s.substr(0, length)
					var json_obj: JSON = JSON.new()
					if json_obj.parse(candidate) == OK:
						return { "success": true, "data": json_obj.data, "length": length }
					return { "success": false, "length": 0 }
	
	return { "success": false, "length": 0 }


## 检查缓冲区是否可以安全地转换为 UTF-8 字符串
func _is_buffer_safe_for_utf8(p_buffer: PackedByteArray) -> bool:
	if p_buffer.is_empty():
		return true
	var len_val: int = p_buffer.size()
	var last_byte: int = p_buffer[len_val - 1]
	
	if (last_byte & 0x80) == 0:
		return true
	if (last_byte & 0xC0) == 0x80:
		var i: int = 1
		while i < 4 and (len_val - 1 - i) >= 0:
			var b: int = p_buffer[len_val - 1 - i]
			if (b & 0xC0) == 0xC0:
				var expected_len: int = 0
				if (b & 0xE0) == 0xC0:
					expected_len = 2
				elif (b & 0xF0) == 0xE0:
					expected_len = 3
				elif (b & 0xF8) == 0xF0:
					expected_len = 4
				
				if (i + 1) < expected_len:
					return false
				else:
					return true
			i += 1
		return true
	if (last_byte & 0xC0) == 0xC0:
		return false
	return true
