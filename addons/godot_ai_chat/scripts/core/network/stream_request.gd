@tool
extends RefCounted
class_name StreamRequest

# [修改] 现在的 chunk_received 信号直接传输原始 JSON 字典，不做任何处理
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
			var _chunk = client.read_response_body_chunk()
		_emit_failure("HTTP Error %d" % response_code)
		return
	
	# 5. 流式读取循环
	var parser_type = _provider.get_stream_parser_type()
	
	while client.get_status() == HTTPClient.STATUS_BODY:
		if _stop_flag: return
		
		client.poll()
		var chunk = client.read_response_body_chunk()
		
		if chunk.size() > 0:
			_incoming_byte_buffer.append_array(chunk)
			
			if _is_buffer_safe_for_utf8(_incoming_byte_buffer):
				var new_text = _incoming_byte_buffer.get_string_from_utf8()
				_incoming_byte_buffer.clear()
				
				_incoming_text_buffer += new_text
				
				if parser_type == BaseLLMProvider.StreamParserType.SSE:
					_process_sse_buffer()
				elif parser_type == BaseLLMProvider.StreamParserType.JSON_LIST:
					_process_json_list_buffer()
					
		OS.delay_msec(10)
	
	call_deferred("emit_signal", "finished")


# --- 协议解析辅助 ---

func _process_sse_buffer() -> void:
	while true:
		var newline_pos = _incoming_text_buffer.find("\n")
		if newline_pos == -1: break
		var line = _incoming_text_buffer.substr(0, newline_pos).strip_edges()
		_incoming_text_buffer = _incoming_text_buffer.substr(newline_pos + 1)
		
		if line.begins_with("data:"):
			var json_str = line.substr(5).strip_edges()
			if json_str == "[DONE]": continue
			var json = JSON.parse_string(json_str)
			if json is Dictionary:
				_emit_raw_json(json)


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
