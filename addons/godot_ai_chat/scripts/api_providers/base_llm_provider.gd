@tool
class_name BaseLLMProvider
extends RefCounted

## LLM 服务提供商的基类
##
## 定义所有 LLM Provider 必须实现的接口，包括请求构建、响应解析与流式处理协议。
## 流式处理契约：
## 1. Provider 只把原始数据块翻译成协议无关的 LLMStreamDelta；
## 2. Provider 不修改 ChatMessage；
## 3. 数据落地由 StreamMessageAssembler 负责。


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


## [可覆写] 开始新一轮流式接收前，重置 Provider 自身的流内状态
## 由消费端在一次请求发起前调用，用于清除上一轮残留的槽位映射等信息
func reset_stream_state() -> void:
	pass


## [必需] 解析一个流式数据块，返回协议无关的增量描述
##
## 实现约定：
## 1. 只读取 p_raw_chunk 与 Provider 自身的流内状态；
## 2. 禁止修改任何 ChatMessage；
## 3. 禁止生成 UI 语义（颜色、状态文案、界面提示）。
##
## [param p_raw_chunk]: 原始数据块（已由传输层切分并解析为 Dictionary）
## [return]: LLMStreamDelta 实例，无任何可提取内容时返回空增量
func parse_stream_chunk(p_raw_chunk: Dictionary) -> LLMStreamDelta:
	return LLMStreamDelta.new()


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


## [模板方法] 构建请求体 (Body)
## 子类请覆写 build_request_body_impl() 而非本方法，以自动获得：
## 1) 全局模型能力表查询（纯文本模型自动剥离图片，防止网关挂起）
## 2) 未来追加的通用预处理逻辑
## [param p_model_name]: 模型名称
## [param p_messages]: 消息历史列表
## [param p_temperature]: 温度参数
## [param p_stream]: 是否开启流式
## [param p_tool_definitions]: 工具定义列表
func build_request_body(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	var request_messages: Array[ChatMessage] = _sanitize_messages(p_messages, p_model_name)
	return build_request_body_impl(p_model_name, request_messages, p_temperature, p_stream, p_tool_definitions)


## [子类覆写] 构建请求体 (Body) 的实际实现
## 子类必须覆写本方法而非 build_request_body，否则会绕过图片净化
func build_request_body_impl(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	push_error("build_request_body_impl() not implemented by " + get_class())
	return {}


## [必需] 解析模型列表响应
## [param p_body_bytes]: 响应体原始字节
func parse_model_list_response(p_body_bytes: PackedByteArray) -> Array[String]:
	return []


## [必需] 解析非流式响应 (完整 Body)
## [param p_body_bytes]: 响应体原始字节
func parse_non_stream_response(p_body_bytes: PackedByteArray) -> Dictionary:
	return {}


## [可覆写] 当前 Provider 是否支持通过 API 端点获取模型列表
## [param p_base_url]: 当前配置的 API Base URL（用于运行时判断，如 DeepSeek 特判）
func supports_model_list_api(p_base_url: String) -> bool:
	return true


## [可覆写] 当前 Provider 是否支持将工具返回的图片直接嵌入 Tool 消息
## Gemini 原生支持 inline_data；OpenAI / Anthropic 需将图片转为独立 User 消息
func supports_inline_tool_images() -> bool:
	return false


## [可覆写] 工具定义是否需要转换为 Gemini 兼容格式（顶展 schema、type 大写）
##
## Gemini 的 functionDeclarations 不接受 OpenAI 的
## {"type":"function","function":{...}} 嵌套结构，调用方据此决定
## 是否经由 ToolRegistry.convert_schema_to_gemini() 转换。
func requires_gemini_tool_schema() -> bool:
	return false


## [可覆写] 返回静态内置模型列表（当 supports_model_list_api() 返回 false 时使用）
func get_static_model_list() -> Array[String]:
	return []


# --- Private Functions ---

# 通用图片净化：查询全局模型能力表，纯文本模型剥离图片
# 必须在副本上操作！p_messages 元素与 ChatMessageHistory.messages 是同一引用，
# 原地 clear 会永久污染历史记录（主 Agent / Sub-Agent / 上下文压缩均受影响）。
# [param p_messages]: 原始消息数组（不会被修改）
# [param p_model_name]: 目标模型名
# [return]: 净化后的消息数组（无图时返回原数组，零拷贝）
func _sanitize_messages(p_messages: Array[ChatMessage], p_model_name: String) -> Array[ChatMessage]:
	if ModelCapabilityTable.supports_image_input(p_model_name):
		return p_messages
	
	var has_image: bool = false
	var sanitized: Array[ChatMessage] = []
	
	for msg: ChatMessage in p_messages:
		if msg.images.is_empty():
			sanitized.append(msg)
			continue
		
		has_image = true
		var clean_msg: ChatMessage = msg.duplicate() as ChatMessage
		clean_msg.images = []
		if clean_msg.content.strip_edges().is_empty():
			clean_msg.content = "[Image attachment removed: model '%s' does not support image input.]" % p_model_name
		sanitized.append(clean_msg)
	
	if has_image:
		var warn_text: String = "[ModelCapabilityTable] Model '%s' is text-only (no vision support). Image content was removed from the request to avoid the API hanging. Update model_capability_table.tres if this model now supports images." % p_model_name
		push_warning(warn_text)
		AIChatLogger.warn(warn_text)
	
	return sanitized
