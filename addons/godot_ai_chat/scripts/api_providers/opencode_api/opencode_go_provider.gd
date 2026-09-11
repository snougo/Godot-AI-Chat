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
	"deepseek-flash",
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
	"qwen3.8-flash",
	"qwen3.7-max",
	"qwen3.7-plus",
	"qwen3.6-plus",
]

## Anthropic Messages API 版本头（opencode 兼容端点必需）
const ANTHROPIC_API_VERSION := "2023-06-01"

## 官方默认 Base URL
const DEFAULT_BASE_URL := "https://opencode.ai/zen/go/v1"

## 客户端 User-Agent：opencode 要求客户端以自身身份标识，而非通用 SDK / HTTP 库名
## （版本号与 plugin.cfg 保持同步）
const USER_AGENT := "GodotAIChat/1.5.0 (Godot Editor Plugin)"

## opencode 会话路由头：同一对话的所有请求必须携带同一个稳定 ID
const SESSION_HEADER := "x-opencode-session"


# --- Static Vars ---

## 当前对话的会话 ID（作为 x-opencode-session 的值）
## [为什么用 static] Provider 由 ProviderFactory 按“每次操作”新建实例，
## 实例变量无法跨请求保持；只有 static 才能让同一对话的多次请求复用同一 ID。
## 为空时会在首次请求前自动生成，保证该请求头永不为空。
static var _session_id: String = ""


# --- Private Vars ---

var _chat_handler: OpenAIChatCompletionsProvider
var _responses_handler: OpenAIResponsesProvider
var _anthropic_handler: AnthropicCompatibleProvider

## 记录最近一次请求的模型名，供流式/非流式解析时路由
var _last_model_name: String = ""

## 已提示过的未知模型集合（实例级去重）
## 注意：Provider 每次操作由 ProviderFactory 新建实例，故去重范围为
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


## 重置三个 Handler 的流内状态
## 路由由 _last_model_name 决定，但为避免实例复用时的状态残留，三个 Handler 全部重置
func reset_stream_state() -> void:
	_chat_handler.reset_stream_state()
	_responses_handler.reset_stream_state()
	_anthropic_handler.reset_stream_state()


## 获取 HTTP 请求头（按模型路由到对应协议的认证方式）
## opencode 的 /v1/messages (Anthropic 兼容) 端点只接受 x-api-key 头，
## 不接受 Authorization: Bearer，否则返回 401 "Missing API key"
## opencode 服务端还要求客户端 (1) 使用自定义 User-Agent 自我标识，
## 每个对话携带稳定的 x-opencode-session，否则返回 400:
## "Request is missing x-opencode-session and cannot be routed efficiently."
func get_request_headers(p_api_key: String, p_stream: bool) -> PackedStringArray:
	var handler: BaseLLMProvider = _get_handler(_last_model_name)
	var headers: PackedStringArray = []
	
	if handler is AnthropicCompatibleProvider:
		headers.append("x-api-key: " + p_api_key)
		headers.append("anthropic-version: " + ANTHROPIC_API_VERSION)
		headers.append("Content-Type: application/json")
		if p_stream:
			headers.append("Accept: text/event-stream")
	else:
		headers = handler.get_request_headers(p_api_key, p_stream)
	
	# opencode 路由标识（模型列表 GET 请求同样经由本方法，需一并携带）
	headers.append("User-Agent: " + USER_AGENT)
	headers.append(SESSION_HEADER + ": " + _get_session_id())
	
	return headers


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


## 解析单个流式数据块（按模型路由到对应协议的 SSE 事件解析）
func parse_stream_chunk(p_raw_chunk: Dictionary) -> LLMStreamDelta:
	return _get_handler(_last_model_name).parse_stream_chunk(p_raw_chunk)


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
	for raw_item: Variant in items:
		if raw_item is Dictionary and raw_item.get("id") is String:
			list.append(String(raw_item["id"]))
		elif raw_item is String:
			list.append(raw_item)
	
	# [P1] 动态解析为空 → 回退静态合并列表兜底
	if list.is_empty():
		return get_static_model_list()
	
	return list


## 返回全部静态模型列表（三种端点风格合并）
## 用途：
## 1) 供 _get_handler 之外的“模型列表数据源兜底”（见 parse_model_list_response）；
## 2) 供外部在 supports_model_list_api=false 场景下回退使用。
func get_static_model_list() -> Array[String]:
	var all_models: Array[String] = []
	all_models.append_array(CHAT_API_ENDPOINT)
	all_models.append_array(RESPONSES_API_ENDPOINT)
	all_models.append_array(ANTHROPIC_API_ENDPOINT)
	return all_models


## 设置当前对话的会话 ID（供会话管理侧在新建/加载/分叉会话时调用）
## [param p_session_id]: 会话标识；传空串表示清除，下次请求前会自动生成新的随机 ID
static func set_conversation_session_id(p_session_id: String) -> void:
	_session_id = p_session_id.strip_edges()


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
	# 单次操作内对同一未知模型仅提示一次（实例级去重，见 _warned_unknown_models 注释）。
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


# 获取当前生效的会话 ID（未设置则懒生成，保证请求头永不为空）
static func _get_session_id() -> String:
	if _session_id.is_empty():
		_session_id = _generate_session_id()
	return _session_id


# 生成 UUID v4 形态的随机会话 ID（opencode 只要求稳定且唯一，不限定格式）
static func _generate_session_id() -> String:
	var bytes: PackedByteArray = Crypto.new().generate_random_bytes(16)
	if bytes.size() != 16:
		# 极端异常兜底：保证返回非空 ID，避免再次触发 400
		return "godot-ai-chat-%d-%d" % [int(Time.get_unix_time_from_system()), randi()]
	
	# 按 RFC 4122 写入版本号 (4) 与变体位
	bytes[6] = (bytes[6] & 0x0F) | 0x40
	bytes[8] = (bytes[8] & 0x3F) | 0x80
	var hex: String = bytes.hex_encode()
	
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8),
		hex.substr(8, 4),
		hex.substr(12, 4),
		hex.substr(16, 4),
		hex.substr(20, 12),
	]
