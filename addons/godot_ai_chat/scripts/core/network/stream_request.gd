@tool
extends RefCounted
class_name StreamRequest

# 现在的 chunk_received 信号直接传输原始 JSON 字典，不做任何处理
signal chunk_received(raw_json: Dictionary)
signal usage_received(usage: Dictionary) # 依然保留，部分 Provider 可能单独发 usage
signal finished
signal failed(error_message: String)

var _provider: BaseLLMProvider
var _url: String
var _headers: PackedStringArray
var _body_json: String
var _stop_flag: bool = false
var _task_id: int = -1

# 双层缓冲机制
var _incoming_byte_buffer: PackedByteArray = PackedByteArray()
var _incoming_text_buffer: String = ""

# 专门用于处理跨行 SSE 数据的持久化缓冲区
var _sse_buffer: String = "" 


func _init(provider: BaseLLMProvider, url: String, headers: PackedStringArray, body_dict: Dictionary) -> void:
	_provider = provider
	_url = url
	_headers = headers
	_body_json = JSON.stringify(body_dict)


func start() -> void:
	_stop_flag = false
	_task_id = WorkerThreadPool.add_task(self._thread_task, false, "Godot AI Chat Stream Request")


func cancel() -> void:
	_stop_flag = true


func _thread_task() -> void:
	var client = HTTPClient.new()
	var err: Error = OK
	
	# 1. 解析 URL
	var protocol_pos = _url.find("://")
	var protocol = _url.substr(0, protocol_pos)
	var rest = _url.substr(protocol_pos + 3)
	var host_end = rest.find("/")
	var host = rest.substr(0, host_end) if host_end != -1 else rest
	var path = rest.substr(host_end) if host_end != -1 else "/"
	var port = 443 if protocol == "https" else 80
	
	if ":" in host:
		var parts = host.split(":")
		host = parts[0]
		port = parts[1].to_int()
	
	# 2. 连接服务器
	var tls_opts = TLSOptions.client() if protocol == "https" else null
	err = client.connect_to_host(host, port, tls_opts)
	if err != OK:
		_emit_failure("Connection failed: %s" % error_string(err))
		return
	
	# 等待连接
	while client.get_status() == HTTPClient.STATUS_CONNECTING or client.get_status() == HTTPClient.STATUS_RESOLVING:
		client.poll()
		if _stop_flag: return
		OS.delay_msec(10)
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		_emit_failure("Could not connect. Status: %d" % client.get_status())
		return
	
	# 3. 发送请求
	err = client.request(HTTPClient.METHOD_POST, path, _headers, _body_json)
	if err != OK:
		_emit_failure("Request sending failed: %s" % error_string(err))
		return
	
	# 4. 等待响应
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		if _stop_flag: return
		OS.delay_msec(10)
	
	if not client.has_response():
		_emit_failure("No response from server.")
		return
	
	var response_code = client.get_response_code()
	if response_code != 200:
		while client.get_status() == HTTPClient.STATUS_BODY:
			client.poll()
			# [建议新增修复]
			if client.get_status() != HTTPClient.STATUS_BODY:
				break
			
			var _chunk = client.read_response_body_chunk()
		_emit_failure("HTTP Error %d" % response_code)
		return
	
	# 5. 流式读取循环
	var parser_type = _provider.get_stream_parser_type()
	
	while client.get_status() == HTTPClient.STATUS_BODY:
		if _stop_flag: return
		
		client.poll()
		
		# poll() 可能会改变状态，如果不再是 STATUS_BODY，读取 chunk 会报错
		if client.get_status() != HTTPClient.STATUS_BODY:
			break
		
		var chunk = client.read_response_body_chunk()
		
		if chunk.size() > 0:
			_incoming_byte_buffer.append_array(chunk)
			
			if _is_buffer_safe_for_utf8(_incoming_byte_buffer):
				var new_text = _incoming_byte_buffer.get_string_from_utf8()
				_incoming_byte_buffer.clear()
				_incoming_text_buffer += new_text
				
				if parser_type == BaseLLMProvider.StreamParserType.SSE:
					_process_sse_buffer()
				elif parser_type == BaseLLMProvider.StreamParserType.LOCAL_SSE:
					_process_sse_buffer()
				elif parser_type == BaseLLMProvider.StreamParserType.JSON_LIST:
					_process_json_list_buffer()
		
		OS.delay_msec(10)
	
	call_deferred("emit_signal", "finished")


# --- 协议解析辅助 --

func _process_sse_buffer() -> void:
	# 循环处理缓冲区中所有完整的行
	while true:
		var newline_pos: int = _incoming_text_buffer.find("\n")
		if newline_pos == -1:
			break # 数据未完整（TCP分包），等待下一次数据到来
		
		# 提取完整的一行（不含换行符）
		var line: String = _incoming_text_buffer.substr(0, newline_pos).strip_edges()
		# 将缓冲区推进到下一行
		_incoming_text_buffer = _incoming_text_buffer.substr(newline_pos + 1)
		
		# 标准 SSE 解析逻辑
		if line.begins_with("data:"):
			var json_raw: String = line.substr(5).strip_edges()
			
			# 忽略结束标记
			if json_raw == "[DONE]":
				continue
			
			if not json_raw.is_empty():
				# [修复] 优先使用 _try_parse_one_json 提取第一个闭合的 JSON 对象
				# 这可以有效忽略 GLM-4.7 等模型输出的尾部垃圾 (如 <tool_call>)
				var result = _try_parse_one_json(json_raw)
				if result.success:
					if result.data is Dictionary:
						_emit_raw_json(result.data)
				else:
					# 如果提取失败，尝试直接解析作为兜底
					var json := JSON.new()
					var err: Error = json.parse(json_raw)
					if err == OK:
						if json.data is Dictionary:
							_emit_raw_json(json.data)
					else:
						push_warning("StreamRequest: Failed to parse SSE JSON chunk. Raw: " + json_raw)


func _process_json_list_buffer() -> void:
	var search_offset = 0
	while true:
		var open_brace = _incoming_text_buffer.find("{", search_offset)
		if open_brace == -1:
			var stripped = _incoming_text_buffer.strip_edges()
			if stripped == "]" or stripped == "," or stripped.is_empty():
				_incoming_text_buffer = ""
			break
		
		if open_brace > 0:
			_incoming_text_buffer = _incoming_text_buffer.substr(open_brace)
			open_brace = 0
			
		var brace_level = 0
		var close_brace = -1
		var in_string = false
		var escape = false
		
		for i in range(open_brace, _incoming_text_buffer.length()):
			var char = _incoming_text_buffer[i]
			if escape: escape = false; continue
			if char == "\\": escape = true; continue
			if char == '"': in_string = not in_string; continue
			if not in_string:
				if char == "{": brace_level += 1
				elif char == "}":
					brace_level -= 1
					if brace_level == 0:
						close_brace = i
						break
		
		if close_brace != -1:
			var json_str = _incoming_text_buffer.substr(open_brace, close_brace - open_brace + 1)
			var json = JSON.parse_string(json_str)
			if json is Dictionary:
				_emit_raw_json(json)
			
			search_offset = close_brace + 1
			_incoming_text_buffer = _incoming_text_buffer.substr(search_offset)
			search_offset = 0
		else:
			break


func _emit_raw_json(json: Dictionary) -> void:
	call_deferred("emit_signal", "chunk_received", json)


func _emit_failure(msg: String) -> void:
	call_deferred("emit_signal", "failed", msg)


# --- 辅助函数 ---

# 尝试从字符串开头解析一个完整的 JSON 对象
func _try_parse_one_json(s: String) -> Dictionary:
	if s.is_empty() or s[0] != "{":
		return { "success": false, "length": 0 }
	
	var balance = 0
	var in_string = false
	var escaped = false
	var length = 0
	
	for i in range(s.length()):
		var char = s[i]
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
					var candidate = s.substr(0, length)
					var json = JSON.new()
					if json.parse(candidate) == OK:
						return { "success": true, "data": json.data, "length": length }
					return { "success": false, "length": 0 }
	
	return { "success": false, "length": 0 }


func _is_buffer_safe_for_utf8(buffer: PackedByteArray) -> bool:
	if buffer.is_empty(): return true
	var len = buffer.size()
	var last_byte = buffer[len - 1]
	if (last_byte & 0x80) == 0: return true
	if (last_byte & 0xC0) == 0x80:
		var i = 1
		while i < 4 and (len - 1 - i) >= 0:
			var b = buffer[len - 1 - i]
			if (b & 0xC0) == 0xC0:
				var expected_len = 0
				if (b & 0xE0) == 0xC0: expected_len = 2
				elif (b & 0xF0) == 0xE0: expected_len = 3
				elif (b & 0xF8) == 0xF0: expected_len = 4
				if (i + 1) < expected_len: return false
				else: return true
			i += 1
		return true
	if (last_byte & 0xC0) == 0xC0: return false
	return true
