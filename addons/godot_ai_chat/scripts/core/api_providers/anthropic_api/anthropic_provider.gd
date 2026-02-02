@tool
class_name AnthropicProvider
extends BaseAnthropicProvider

## Anthropic 官方服务提供商
##
## 配置了官方 API 端点和鉴权头。


# --- Public Functions ---

## 获取 HTTP 请求头
func get_request_headers(p_api_key: String, _p_stream: bool) -> PackedStringArray:
	var headers: PackedStringArray = []
	headers.append("x-api-key: " + p_api_key)
	headers.append("anthropic-version: 2023-06-01") # 固定 API 版本
	headers.append("content-type: application/json")
	
	# Anthropic 不需要显式的 Accept: text/event-stream，但加上也没坏处
	
	return headers


## 获取请求的 URL
func get_request_url(p_base_url: String, _p_model: String, _p_key: String, _p_stream: bool) -> String:
	# 允许用户覆盖 Base URL (例如使用代理)
	var url: String = p_base_url.strip_edges()
	
	if url.is_empty():
		return "https://api.anthropic.com/v1/messages"
	
	# 智能拼接路径：如果用户只填了域名
	if not url.ends_with("/messages"):
		if not url.ends_with("/v1"):
			url = url.path_join("v1")
		url = url.path_join("messages")
	
	return url
