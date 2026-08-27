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
## 模型获取策略（双轨制）：
## 1. 动态获取：调用官方 {base}/models 端点（supports_model_list_api=true）。
## 2. 路由映射：端点类型无法从 /models 响应中获知，故路由仍依赖下方静态常量。
##    若动态获取到未知模型，默认走 Chat Completions 并打 warning。
## 3. 静态兜底：动态解析为空（HTTP 200 但格式不符/代理异常）时，
##    parse_model_list_response 自动回退到 get_static_model_list() 的合并列表。
##
## 官方文档:   https://opencode.ai/docs/zh-cn/go
## 官方 Base URL: https://opencode.ai/zen/go/v1

# --- Constants ---

## OpenAI Chat Completions 兼容模型
## （官方端点表 @ai-sdk/openai-compatible 对应的模型）
const CHAT_API_ENDPOINT: Array[String] = [
	"glm-5.3-flash",
	"glm-5.3",
	"glm-5.2",
	"glm-5.1",
	"kimi-k3",
	"kimi-k2.7-code",
	"kimi-k2.6",
	"deepseek-v4-pro",
	"deepseek-v4-flash",
	"deepseek-v4-flash-vision-exp",
	"mimo-v2.5",
	"mimo-v2.5-pro",
	"hy3",
	"longcat-2.0",
]

## OpenAI Responses 兼容模型
## （官方端点表 @ai-sdk/openai 对应的模型）
const RESPONSES_API_ENDPOINT: Array[String] = [
	"gpt-5.6-luna",
	"grok-4.6",
	"muse-spark-1.2-contributor",
]

## Anthropic Messages 兼容模型
## （官方端点表 @ai-sdk/anthropic 对应的模型）
const ANTHROPIC_API_ENDPOINT: Array[String] = [
	"minimax-m3",
	"minimax-m2.7",
	"minimax-m2.5",
	"qwen3.8-max",
	"qwen3.7-max",
	"qwen3.7-plus",
	"qwen3.6-plus",
]

## Anthropic Messages API 版本头（opencode 兼容端点必需）
const ANTHROPIC_API_VERSION := "2023-06-01"

## 官方默认 Base URL
const DEFAULT_BASE_URL := "https://opencode.ai/zen/go/v1"

# --- Private Vars ---

var _chat_handler: OpenAIChatCompletionsProvider
var _responses_handler: OpenAIResponsesProvider
var _anthropic_handler: AnthropicCompatibleProvider
## 记录最近一次请求的模型名，供流式/非流式解析时路由
var _last_model_name: String = ""
## 已提示过的未知模型集合（实例级去重）
## [P3] 注意：Provider 每次操作由 ProviderFactory 新建实例，故去重范围为
## “单次操作内，同一未知模型仅提示一次”；跨操作（新实例）会重新提示。
## 此为本意：既避免单次请求内重复刷屏，又保留对未知模型的持续可见提醒。
var _warned_unknown_models: Dictionary = {}


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
	var handler: BaseLLMProvider = _get_handler(_last_model_name)
	if handler is AnthropicCompatibleProvider:
		var headers: PackedStringArray = []
		headers.append("x-api-key: " + p_api_key)
		headers.append("anthropic-version: " + ANTHROPIC_API_VERSION)
		headers.append("Content-Type: application/json")
		if p_stream:
			headers.append("Accept: text/event-stream")
		return headers
	return handler.get_request_headers(p_api_key, p_stream)


## 获取请求 URL（按模型路由到对应端点）
## [p_model_name] 为空时返回 {base}/models，用于动态获取模型列表
func get_request_url(p_base_url: String, p_model_name: String, p_api_key: String, p_stream: bool) -> String:
	var handler: BaseLLMProvider = _get_handler(p_model_name)
	var base: String = _normalize_base_url(p_base_url)
	_last_model_name = p_model_name
	# 模型列表请求：官方端点 {base}/models
	if p_model_name.is_empty():
		return _chat_handler.get_request_url(base, "", p_api_key, p_stream)
	return handler.get_request_url(base, p_model_name, p_api_key, p_stream)


## [子类覆写] 构建请求体（按模型路由到对应协议格式）
## 图片净化已由基类模板方法 build_request_body 统一完成
func build_request_body_impl(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	_last_model_name = p_model_name
	return _get_handler(p_model_name).build_request_body(p_model_name, p_messages, p_temperature, p_stream, p_tool_definitions)


## 解析非流式响应（按模型路由，用于上下文压缩等场景）
func parse_non_stream_response(p_body_bytes: PackedByteArray) -> Dictionary:
	return _get_handler(_last_model_name).parse_non_stream_response(p_body_bytes)


## 处理流式响应块（按模型路由到对应 SSE 事件解析）
func process_stream_chunk(p_target_msg: ChatMessage, p_chunk_data: Dictionary) -> Dictionary:
	return _get_handler(_last_model_name).process_stream_chunk(p_target_msg, p_chunk_data)


## [启用] 官方提供 {base}/models 端点，支持动态获取模型列表
func supports_model_list_api(_p_base_url: String) -> bool:
	return true


## 解析模型列表响应（防御性，兼容多种可能的响应格式）
## 官方 /models 端点格式未经实测，故对以下格式做兼容：
## 1) OpenAI 兼容： {"object":"list","data":[{"id":"..."}, ...]}
## 2) Anthropic 兼容： {"data":[{"id":"..."}, ...]}
## 3) 直接数组：     [{"id":"..."}, ...] 或 ["model-id", ...]
## [P1] 解析为空（格式不符/异常响应）时回退静态合并列表，
##      让 get_static_model_list() 的兜底职责真正生效。
## [注意] 仅覆盖"HTTP 200 但解析为空"；HTTP 非 200 仍由 NetworkManager 如实报错。
func parse_model_list_response(p_body_bytes: PackedByteArray) -> Array[String]:
	var json: Variant = JSON.parse_string(p_body_bytes.get_string_from_utf8())
	var list: Array[String] = []
	
	# 统一取出待遍历的条目数组
	var items: Array = []
	if json is Dictionary and json.get("data") is Array:
		items = json["data"]
	elif json is Array:
		items = json
	
	# 提取模型 id（兼容 Dictionary 条目与纯 String 条目）
	for item in items:
		if item is Dictionary and item.get("id") is String:
			list.append(item["id"])
		elif item is String:
			list.append(item)
	
	# [P1] 动态解析为空 → 回退静态合并列表兜底
	if list.is_empty():
		return get_static_model_list()
	
	return list


## 返回全部静态模型列表（三种端点风格合并）
## 用途：1) 供 _get_handler 之外的“模型列表数据源兜底”（见 parse_model_list_response）；
##       2) 供外部在 supports_model_list_api=false 场景下回退使用。
func get_static_model_list() -> Array[String]:
	var all_models: Array[String] = []
	all_models.append_array(CHAT_API_ENDPOINT)
	all_models.append_array(RESPONSES_API_ENDPOINT)
	all_models.append_array(ANTHROPIC_API_ENDPOINT)
	return all_models


# --- Private Functions ---

# 按模型名返回对应的协议 Handler
# [param p_model_name]: 模型名
# [return]: 对应的协议 Handler；未知模型兜底走 _chat_handler 并打 warning
func _get_handler(p_model_name: String) -> BaseLLMProvider:
	if p_model_name in RESPONSES_API_ENDPOINT:
		return _responses_handler
	if p_model_name in ANTHROPIC_API_ENDPOINT:
		return _anthropic_handler
	# 已知 Chat 模型静默返回，不进兜底 warning 分支
	if p_model_name in CHAT_API_ENDPOINT:
		return _chat_handler
	# 未知模型兜底：官方 /models 仅含 id，无法判断端点风格。
	# opencode 绝大多数模型为 Chat Completions 风格，故默认走 _chat_handler。
	# [P3] 单次操作内对同一未知模型仅提示一次（实例级去重，见 _warned_unknown_models 注释）。
	# 若选了根端点类型新模型导致调用失败，请将模型 id 补入对应常量。
	if not p_model_name.is_empty() and not _warned_unknown_models.has(p_model_name):
		_warned_unknown_models[p_model_name] = true
		push_warning("[OpenCodeGo]: Unknown model '%s' not in endpoint mapping constants, routing to Chat Completions by default. Update CHAT_API_ENDPOINT/RESPONSES_API_ENDPOINT/ANTHROPIC_API_ENDPOINT if routing is wrong." % p_model_name)
	return _chat_handler


# 规范化 Base URL：补全协议头、去除末尾斜杠、空值兜底
# [param p_base_url]: 用户配置的 Base URL
# [return]: 规范化后的 URL
func _normalize_base_url(p_base_url: String) -> String:
	var url: String = p_base_url.strip_edges()
	if url.is_empty():
		return DEFAULT_BASE_URL
	if url.find("://") == -1:
		url = "https://" + url
	while url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	return url
