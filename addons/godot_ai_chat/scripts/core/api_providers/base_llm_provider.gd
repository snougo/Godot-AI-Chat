@tool
class_name BaseLLMProvider
extends RefCounted

## LLM 服务提供商的基类
##
## 定义了所有 LLM Provider 必须实现的接口，包括请求构建、响应解析和流式处理协议。

# --- Enums / Constants ---

## 流式响应解析协议类型
enum StreamParserType {
	SSE,       # Server-Sent Events (OpenAI, Zhipu, etc.)
	JSON_LIST, # JSON Array Stream (Gemini)
	LOCAL_SSE  # 针对本地服务的鲁棒性解析
}

# --- Public Functions ---

## [必需] 返回该 Provider 使用的流式解析协议
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


## [必需] 获取 HTTP 请求头
## [param p_api_key]: API 密钥
## [param p_stream]: 是否为流式请求
func get_request_headers(p_api_key: String, p_stream: bool) -> PackedStringArray:
	return []


## [必需] 获取请求的 URL
## [param p_base_url]: 基础 URL
## [param p_model_name]: 模型名称
## [param p_api_key]: API 密钥（部分接口可能需要）
## [param p_stream]: 是否为流式请求
func get_request_url(p_base_url: String, p_model_name: String, p_api_key: String, p_stream: bool) -> String:
	return ""


## [必需] 构建请求体 (Body)
## [param p_model_name]: 模型名称
## [param p_messages]: 消息历史列表
## [param p_temperature]: 温度参数
## [param p_stream]: 是否开启流式
## [param p_tool_definitions]: 工具定义列表
func build_request_body(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	return {}


## [必需] 解析模型列表响应
## [param p_body_bytes]: 响应体原始字节
func parse_model_list_response(p_body_bytes: PackedByteArray) -> Array[String]:
	return []


## [必需] 解析非流式响应 (完整 Body)
## [param p_body_bytes]: 响应体原始字节
func parse_non_stream_response(p_body_bytes: PackedByteArray) -> Dictionary:
	return {}


## 处理流式响应块
## 接收原始网络数据(raw_chunk)，直接修改目标消息对象(target_msg)的数据层
## 返回 UI 需要的增量信息： { "content_delta": String, "usage": Dictionary (可选) }
## [param p_target_msg]: 目标消息对象（将被修改）
## [param p_raw_chunk]: 原始数据块
func process_stream_chunk(p_target_msg: ChatMessage, p_raw_chunk: Dictionary) -> Dictionary:
	return { "content_delta": "" }
