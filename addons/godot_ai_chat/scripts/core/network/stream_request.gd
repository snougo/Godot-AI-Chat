@tool
class_name StreamRequest
extends RefCounted

## 负责底层的 HTTP 流式请求处理，支持 SSE 和 JSON List 协议。

# --- Signals ---

## 当接收到一个完整的 JSON 数据块时触发
signal chunk_received(raw_json: Dictionary)
## 当接收到 Usage 数据时触发（部分 Provider 可能单独发送）
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
var _stop_flag: bool = false
var _task_id: int = -1

## 双层缓冲机制：字节缓冲
var _incoming_byte_buffer: PackedByteArray = PackedByteArray()
## 双层缓冲机制：文本缓冲
var _incoming_text_buffer: String = ""
## 专门用于处理跨行 SSE 数据的持久化缓冲区
var _sse_buffer: String = "" 

# --- Built-in Functions ---

func _init(_provider_inst: BaseLLMProvider, _request_url: String, _request_headers: PackedStringArray, _body_dict: Dictionary) -> void:
	_provider = _provider_inst
	_url = _request_url
	_headers = _request_headers
	_body_json = JSON.stringify(_body_dict)

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
	var _client: HTTPClient = HTTPClient.new()
	var _err: Error = OK
	
	# 1. 解析 URL
	var _protocol_pos: int = _url.find("://")
	var _protocol: String = _url.substr(0, _protocol_pos)
	var _rest: String = _url.substr(_protocol_pos + 3)
	var _host_end: int = _rest.find("/")
	var _host: String = _rest.substr(0, _host_end) if _host_end != -1 else _rest
	var _path: String = _rest.substr(_host_end) if _host_end != -1 else "/"
	var _port: int = 443 if _protocol == "https" else 80
	
	if ":" in _host:
		var _parts: PackedStringArray = _host.split(":")
		_host = _parts[0]
		_port = _parts[1].to_int()
	
	# 2. 连接服务器
	var _tls_opts: TLSOptions = TLSOptions.client() if _protocol == "https" else null
	_err = _client.connect_to_host(_host, _port, _tls_opts)
	if _err != OK:
		_emit_failure("Connection failed: %s" % error_string(_err))
		return
	
	# 等待连接
	while _client.get_status() == HTTPClient.STATUS_CONNECTING or _client.get_status() == HTTPClient.STATUS_RESOLVING:
		_client.poll()
		if _stop_flag: return
		OS.delay_msec(10)
	
	if _client.get_status() != HTTPClient.STATUS_CONNECTED:
		_emit_failure("Could not connect. Status: %d" % _client.get_status())
		return
	
	# 3. 发送请求
	_err = _client.request(HTTPClient.METHOD_POST, _path, _headers, _body_json)
	if _err != OK:
		_emit_failure("Request sending failed: %s" % error_string(_err))
		return
	
	# 4. 等待响应
	while _client.get_status() == HTTPClient.STATUS_REQUESTING:
		_client.poll()
		if _stop_flag: return
		OS.delay_msec(10)
	
	if not _client.has_response():
		_emit_failure("No response from server.")
		return
	
	var _response_code: int = _client.get_response_code()
	if _response_code != 200:
		while _client.get_status() == HTTPClient.STATUS_BODY:
			_client.poll()
			if _client.get_status() != HTTPClient.STATUS_BODY:
				break
			var _dummy_chunk: PackedByteArray = _client.read_response_body_chunk()
		_emit_failure("HTTP Error %d" % _response_code)
		return
	
	# 5. 流式读取循环
	var _parser_type: BaseLLMProvider.StreamParserType = _provider.get_stream_parser_type()
	
	while _client.get_status() == HTTPClient.STATUS_BODY:
		if _stop_flag: return
		
		_client.poll()
		
		# poll() 可能会改变状态，如果不再是 STATUS_BODY，读取 chunk 会报错
		if _client.get_status() != HTTPClient.STATUS_BODY:
			break
		
		var _chunk: PackedByteArray = _client.read_response_body_chunk()
		
		if _chunk.size() > 0:
			_incoming_byte_buffer.append_array(_chunk)
			
			if _is_buffer_safe_for_utf8(_incoming_byte_buffer):
				var _new_text: String = _incoming_byte_buffer.get_string_from_utf8()
				_incoming_byte_buffer.clear()
				_incoming_text_buffer += _new_text
				
				if _parser_type == BaseLLMProvider.StreamParserType.SSE or _parser_type == BaseLLMProvider.StreamParserType.LOCAL_SSE:
					_process_sse_buffer()
				elif _parser_type == BaseLLMProvider.StreamParserType.JSON_LIST:
					_process_json_list_buffer()
		
		OS.delay_msec(10)
	
	finished.emit.call_deferred()


## 处理 SSE 协议缓冲区
func _process_sse_buffer() -> void:
	while true:
		var _newline_pos: int = _incoming_text_buffer.find("\n")
		if _newline_pos == -1:
			break
		
		var _line: String = _incoming_text_buffer.substr(0, _newline_pos).strip_edges()
		_incoming_text_buffer = _incoming_text_buffer.substr(_newline_pos + 1)
		
		if _line.begins_with("data:"):
			var _json_raw: String = _line.substr(5).strip_edges()
			
			if _json_raw == "[DONE]":
				continue
			
			if not _json_raw.is_empty():
				var _result: Dictionary = _try_parse_one_json(_json_raw)
				if _result.success:
					if _result.data is Dictionary:
						_emit_raw_json(_result.data)
				else:
					var _json_obj: JSON = JSON.new()
					var _err: Error = _json_obj.parse(_json_raw)
					if _err == OK:
						if _json_obj.data is Dictionary:
							_emit_raw_json(_json_obj.data)
					else:
						push_warning("StreamRequest: Failed to parse SSE JSON chunk. Raw: " + _json_raw)


## 处理 JSON List 协议缓冲区 (Gemini)
func _process_json_list_buffer() -> void:
	var _search_offset: int = 0
	while true:
		var _open_brace: int = _incoming_text_buffer.find("{", _search_offset)
		if _open_brace == -1:
			var _stripped: String = _incoming_text_buffer.strip_edges()
			if _stripped == "]" or _stripped == "," or _stripped.is_empty():
				_incoming_text_buffer = ""
			break
		
		if _open_brace > 0:
			_incoming_text_buffer = _incoming_text_buffer.substr(_open_brace)
			_open_brace = 0
			
		var _brace_level: int = 0
		var _close_brace: int = -1
		var _in_string: bool = false
		var _escape: bool = false
		
		for _i in range(_open_brace, _incoming_text_buffer.length()):
			var _char: String = _incoming_text_buffer[_i]
			if _escape: 
				_escape = false
				continue
			if _char == "\\": 
				_escape = true
				continue
			if _char == '"': 
				_in_string = not _in_string
				continue
			if not _in_string:
				if _char == "{": 
					_brace_level += 1
				elif _char == "}":
					_brace_level -= 1
					if _brace_level == 0:
						_close_brace = _i
						break
		
		if _close_brace != -1:
			var _json_str: String = _incoming_text_buffer.substr(_open_brace, _close_brace - _open_brace + 1)
			var _json_val: Variant = JSON.parse_string(_json_str)
			if _json_val is Dictionary:
				_emit_raw_json(_json_val)
			
			_search_offset = _close_brace + 1
			_incoming_text_buffer = _incoming_text_buffer.substr(_search_offset)
			_search_offset = 0
		else:
			break


## 延迟发射 JSON 数据信号
func _emit_raw_json(_json: Dictionary) -> void:
	chunk_received.emit.call_deferred(_json)


## 延迟发射失败信号
func _emit_failure(_msg: String) -> void:
	failed.emit.call_deferred(_msg)


## 尝试从字符串开头解析一个完整的 JSON 对象
func _try_parse_one_json(_s: String) -> Dictionary:
	if _s.is_empty() or _s[0] != "{":
		return { "success": false, "length": 0 }
	
	var _balance: int = 0
	var _in_string: bool = false
	var _escaped: bool = false
	var _length: int = 0
	
	for _i in range(_s.length()):
		var _char: String = _s[_i]
		_length += 1
		
		if _escaped:
			_escaped = false
			continue
		if _char == "\\":
			_escaped = true
			continue
		if _char == '"':
			_in_string = not _in_string
			continue
		
		if not _in_string:
			if _char == '{':
				_balance += 1
			elif _char == '}':
				_balance -= 1
				if _balance == 0:
					var _candidate: String = _s.substr(0, _length)
					var _json_obj: JSON = JSON.new()
					if _json_obj.parse(_candidate) == OK:
						return { "success": true, "data": _json_obj.data, "length": _length }
					return { "success": false, "length": 0 }
	
	return { "success": false, "length": 0 }


## 检查缓冲区是否可以安全地转换为 UTF-8 字符串（防止截断多字节字符）
func _is_buffer_safe_for_utf8(_buffer: PackedByteArray) -> bool:
	if _buffer.is_empty(): return true
	var _len: int = _buffer.size()
	var _last_byte: int = _buffer[_len - 1]
	if (_last_byte & 0x80) == 0: return true
	if (_last_byte & 0xC0) == 0x80:
		var _i: int = 1
		while _i < 4 and (_len - 1 - _i) >= 0:
			var _b: int = _buffer[_len - 1 - _i]
			if (_b & 0xC0) == 0xC0:
				var _expected_len: int = 0
				if (_b & 0xE0) == 0xC0: _expected_len = 2
				elif (_b & 0xF0) == 0xE0: _expected_len = 3
				elif (_b & 0xF8) == 0xF0: _expected_len = 4
				if (_i + 1) < _expected_len: return false
				else: return true
			_i += 1
		return true
	if (_last_byte & 0xC0) == 0xC0: return false
	return true
