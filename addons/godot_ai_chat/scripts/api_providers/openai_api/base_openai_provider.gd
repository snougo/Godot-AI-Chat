@tool
class_name BaseOpenAIProvider
extends BaseLLMProvider

## OpenAI 兼容接口的抽象基类
##
## 提供共享的 HTTP 头、模型列表解析等通用逻辑。
## Chat Completions 和 Responses API 的请求/响应格式由子类各自实现。


# --- Public Functions ---

## 返回该 Provider 使用的流式解析协议
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


## 获取 HTTP 请求头
func get_request_headers(p_api_key: String, p_stream: bool) -> PackedStringArray:
	var headers: PackedStringArray = ["Content-Type: application/json"]
	headers.append("Accept-Encoding: identity")
	
	if p_stream:
		headers.append("Accept: text/event-stream")
	
	if not p_api_key.is_empty():
		headers.append("Authorization: Bearer " + p_api_key)
	
	return headers


## 解析模型列表响应
func parse_model_list_response(p_body_bytes: PackedByteArray) -> Array[String]:
	var json: Variant = JSON.parse_string(p_body_bytes.get_string_from_utf8())
	var list: Array[String] = []
	
	if json is Dictionary and json.has("data"):
		for item in json.data:
			if item.has("id"):
				list.append(item.id)
	
	return list
