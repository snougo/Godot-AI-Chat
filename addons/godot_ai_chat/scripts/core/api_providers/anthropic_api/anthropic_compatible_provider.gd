@tool
class_name AnthropicCompatibleProvider
extends BaseAnthropicProvider

## 通用 Anthropic 兼容服务提供商
##
## 用于连接支持 Anthropic /v1/messages 协议的第三方服务。
## 例如：OpenRouter, OneAPI, 或其他兼容网关。
## 特性：
## 1. 使用 Bearer Token 鉴权 (而非官方的 x-api-key)。
## 2. 自动修正 Base URL 路径。
## 警告：切勿在日志中打印 API Key

# --- Constants ---

#const ANTHROPIC_API_VERSION := "2023-06-01"


# --- Public Functions ---

## 获取 HTTP 请求头
## 警告：p_api_key 包含敏感信息，切勿记录到日志
func get_request_headers(p_api_key: String, _p_stream: bool) -> PackedStringArray:
	var headers: PackedStringArray = []
	# 大多数兼容 API (如 OpenRouter, OneAPI) 使用标准 Bearer Token
	headers.append("Authorization: Bearer " + p_api_key)
	# 部分网关可能还需要 anthropic-version，加上比较保险
	#headers.append("anthropic-version: " + ANTHROPIC_API_VERSION)
	headers.append("Content-Type: application/json")
	return headers


## 获取请求的 URL
func get_request_url(p_base_url: String, p_model: String, _p_key: String, _p_stream: bool) -> String:
	# 如果 model 为空，通常意味着这是在请求模型列表 (NetworkManager.get_model_list)
	# 或者是某些特殊的检查。
	# 大多数兼容网关使用 /v1/models 来获取列表
	if p_model.is_empty(): 
		return _build_url(p_base_url, "models")
	
	return _build_url(p_base_url, "messages")


## 解析模型列表响应
## 兼容网关通常返回 OpenAI 格式的 { data: [{id: ...}] }
func parse_model_list_response(p_body_bytes: PackedByteArray) -> Array[String]:
	var json_str: String = p_body_bytes.get_string_from_utf8()
	var json: Variant = JSON.parse_string(json_str)
	var list: Array[String] = []
	
	if json == null:
		AIChatLogger.error("[AnthropicAPI]: Failed to parse model list JSON")
		return []
	
	if json is Dictionary and json.has("data") and json.data is Array:
		for item in json.data:
			if item is Dictionary and item.has("id") and item.id is String:
				list.append(item.id)
	
	# 如果解析失败或列表为空，返回空数组（而非包含空字符串的数组）
	if list.is_empty():
		push_warning("[AnthropicAI]: No models found in response or empty data")
		return []
	
	return list


func _build_url(p_base: String, p_endpoint: String) -> String:
	var url: String = p_base.strip_edges()
	
	# 统一移除末尾斜杠
	while url.ends_with("/"):
		url = url.left(url.length() - 1)
	
	# 检查是否已包含完整路径
	var full_path := "/v1/" + p_endpoint
	if url.ends_with(full_path):
		return url  # 已经是完整路径，直接返回
	
	# 如果以 /v1 结尾，直接追加端点
	if url.ends_with("/v1"):
		return url + "/" + p_endpoint
	
	# 如果包含其他版本路径（如 /v2），警告但尊重用户输入
	if url.contains("/v"):
		push_warning("AnthropicCompatibleProvider: URL contains non-standard version path: " + url)
	
	# 标准拼接：添加 /v1/endpoint
	return url + "/v1/" + p_endpoint
