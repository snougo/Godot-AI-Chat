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


# --- Public Functions ---

## 获取 HTTP 请求头
func get_request_headers(p_api_key: String, _p_stream: bool) -> PackedStringArray:
	var headers: PackedStringArray = []
	# 大多数兼容 API (如 OpenRouter, OneAPI) 使用标准 Bearer Token
	headers.append("Authorization: Bearer " + p_api_key)
	# 部分网关可能还需要 anthropic-version，加上比较保险
	headers.append("anthropic-version: 2023-06-01") 
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
	var json: Variant = JSON.parse_string(p_body_bytes.get_string_from_utf8())
	var list: Array[String] = []
	
	if json is Dictionary and json.has("data"):
		for item in json.data:
			if item.has("id"):
				list.append(item.id)
	
	# 如果解析失败或列表为空（比如官方API），返回默认推荐列表
	if list.is_empty():
		return [
			"deepseek-ai/DeepSeek-R1",
			"deepseek-ai/DeepSeek-V3", 
			"claude-3-5-sonnet-20240620",
			"claude-3-opus-20240229"
		]
	
	return list


func _build_url(p_base: String, p_endpoint: String) -> String:
	var url = p_base.strip_edges()
	if url.ends_with("/"): url = url.substr(0, url.length() - 1)
	
	# 如果用户已经填了完整路径，尝试智能剥离
	if url.ends_with("/messages"):
		url = url.replace("/messages", "")
	elif url.ends_with("/chat/completions"):
		url = url.replace("/chat/completions", "")
	
	if not url.ends_with("/v1"):
		url += "/v1"
	
	return url + "/" + p_endpoint
