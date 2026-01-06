@tool
extends RefCounted
class_name BaseLLMProvider

# 定义流式协议类型
enum StreamParserType {
	SSE,       # Server-Sent Events (OpenAI, Zhipu, etc.)
	JSON_LIST,  # JSON Array Stream (Gemini)
	LOCAL_SSE  # 针对本地服务的鲁棒性解析
}


# [必需] 返回该 Provider 使用的流式解析协议
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


# [必需] 获取 HTTP 请求头
func get_request_headers(_api_key: String, _stream: bool) -> PackedStringArray:
	return []


# [必需] 获取请求的 URL
func get_request_url(_base_url: String, _model_name: String, _api_key: String, _stream: bool) -> String:
	return ""


# [必需] 构建请求体 (Body)
func build_request_body(_model_name: String, _messages: Array[ChatMessage], _temperature: float, _stream: bool, _tool_definitions: Array = []) -> Dictionary:
	return {}


# [必需] 解析模型列表响应
func parse_model_list_response(_body_bytes: PackedByteArray) -> Array[String]:
	return []


# [必需] 解析非流式响应 (完整 Body)
func parse_non_stream_response(_body_bytes: PackedByteArray) -> Dictionary:
	return {}


# [架构核心变更]
# 接收原始网络数据(raw_chunk)，直接修改目标消息对象(target_msg)的数据层
# 返回 UI 需要的增量信息： { "content_delta": String, "usage": Dictionary (可选) }
func process_stream_chunk(_target_msg: ChatMessage, _raw_chunk: Dictionary) -> Dictionary:
	return { "content_delta": "" }
