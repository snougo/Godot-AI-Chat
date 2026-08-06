@tool
class_name OpenCodeGoProvider
extends BaseLLMProvider

## OpenCode Go 服务提供商（混合端点实现）
##
## OpenCode Go (https://opencode.ai/go) 的 API 混合了三种端点风格：
## - OpenAI Chat Completions: {base}/chat/completions
## - OpenAI Responses:        {base}/responses
## - Anthropic Messages:      {base}/messages
##
## 本 Provider 内部持有三个对应协议的 Handler，根据模型名自动路由，
## 对外呈现为单一 Provider，模型下拉框可统一选择全部模型。
##
## 官方文档:   https://opencode.ai/docs/zh-cn/go
## 官方 Base URL: https://opencode.ai/zen/go/v1 （不是 /api/v1！）

# --- Constants ---

## OpenAI Chat Completions 兼容模型
const CHAT_MODELS: Array[String] = [
	"grok-4.5",
	"glm-5.2",
	"kimi-k3",
	"deepseek-v4-pro",
	"deepseek-v4-flash"
]

## OpenAI Responses 兼容模型
const RESPONSES_MODELS: Array[String] = ["gpt-5.6-luna"]

## Anthropic Messages 兼容模型
const ANTHROPIC_MODELS: Array[String] = [
	"minimax-m3",
	"qwen3.8-max",
]

## Anthropic Messages API 版本头（opencode 兼容端点必需）
const ANTHROPIC_API_VERSION := "2023-06-01"

# --- Private Vars ---

var _chat_handler: OpenAIChatCompletionsProvider
var _responses_handler: OpenAIResponsesProvider
var _anthropic_handler: AnthropicCompatibleProvider
## 记录最近一次请求的模型名，供流式/非流式解析时路由
var _last_model_name: String = ""


# --- Built-in Functions ---

func _init() -> void:
	_chat_handler = OpenAIChatCompletionsProvider.new()
	_responses_handler = OpenAIResponsesProvider.new()
	_anthropic_handler = AnthropicCompatibleProvider.new()


# --- Public Functions ---

## 三种端点均为 SSE 协议
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


## 获取 HTTP 请求头（按模型路由到对应协议的认证方式）
## [修复] opencode 的 /v1/messages (Anthropic 兼容) 端点只接受 x-api-key 头，
## 不接受 Authorization: Bearer，否则返回 401 "Missing API key"
func get_request_headers(p_api_key: String, p_stream: bool) -> PackedStringArray:
	if _get_handler(_last_model_name) is AnthropicCompatibleProvider:
		var headers: PackedStringArray = []
		headers.append("x-api-key: " + p_api_key)
		headers.append("anthropic-version: " + ANTHROPIC_API_VERSION)
		headers.append("Content-Type: application/json")
		if p_stream:
			headers.append("Accept: text/event-stream")
		return headers
	return _get_handler(_last_model_name).get_request_headers(p_api_key, p_stream)


## 获取请求 URL（按模型路由到对应端点）
func get_request_url(p_base_url: String, p_model_name: String, p_api_key: String, p_stream: bool) -> String:
	_last_model_name = p_model_name
	var base: String = _normalize_base_url(p_base_url)
	# 模型列表请求：本 Provider 使用静态列表，此处仅返回基础 URL（实际不会被调用）
	if p_model_name.is_empty():
		return base
	return _get_handler(p_model_name).get_request_url(base, p_model_name, p_api_key, p_stream)


## 构建请求体（按模型路由到对应协议格式）
func build_request_body(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	_last_model_name = p_model_name
	return _get_handler(p_model_name).build_request_body(p_model_name, p_messages, p_temperature, p_stream, p_tool_definitions)


## 解析非流式响应（按模型路由，用于上下文压缩等场景）
func parse_non_stream_response(p_body_bytes: PackedByteArray) -> Dictionary:
	return _get_handler(_last_model_name).parse_non_stream_response(p_body_bytes)


## 处理流式响应块（按模型路由到对应 SSE 事件解析）
func process_stream_chunk(p_target_msg: ChatMessage, p_chunk_data: Dictionary) -> Dictionary:
	return _get_handler(_last_model_name).process_stream_chunk(p_target_msg, p_chunk_data)


## OpenCode Go 官方虽有 {base}/models 端点，但返回全部端点风格模型，
## 且该端点可用性未经充分验证，故关闭动态拉取，使用内置静态列表
func supports_model_list_api(_p_base_url: String) -> bool:
	return false


## 返回全部模型列表（三种端点风格合并）
func get_static_model_list() -> Array[String]:
	var all_models: Array[String] = []
	all_models.append_array(CHAT_MODELS)
	all_models.append_array(RESPONSES_MODELS)
	all_models.append_array(ANTHROPIC_MODELS)
	return all_models


# --- Private Functions ---

# 按模型名返回对应的协议 Handler
# [param p_model_name]: 模型名
# [return]: 对应的协议 Handler
func _get_handler(p_model_name: String) -> BaseLLMProvider:
	if p_model_name in RESPONSES_MODELS:
		return _responses_handler
	if p_model_name in ANTHROPIC_MODELS:
		return _anthropic_handler
	return _chat_handler


# 规范化 Base URL：补全协议头、去除末尾斜杠、空值兜底
# [param p_base_url]: 用户配置的 Base URL
# [return]: 规范化后的 URL
func _normalize_base_url(p_base_url: String) -> String:
	var url: String = p_base_url.strip_edges()
	if url.is_empty():
		return "https://opencode.ai/zen/go/v1"
	if url.find("://") == -1:
		url = "https://" + url
	while url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	return url
