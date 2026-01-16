@tool
class_name ZhipuAIProvider
extends BaseOpenAIProvider

## 智谱 AI (ZhipuAI) 的服务提供商实现。

# --- Constants ---

## 智谱AI支持的模型列表（硬编码，因为API不提供模型列表端点）
const ZHIPUAI_MODELS: Array[String] = ["glm-4.5-air"]

# --- Public Functions ---

## 智谱 V4 完美兼容 SSE
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


## 获取模型列表URL（智谱AI不提供此端点，返回空字符串）
func get_model_list_url(_base_url: String) -> String:
	return ""


## 重写模型列表解析 - 直接返回硬编码的模型列表
func parse_model_list_response(_body_bytes: PackedByteArray) -> Array[String]:
	return ZHIPUAI_MODELS


## 智谱 V4 的 URL 规则：固定为 /api/paas/v4/chat/completions
func get_request_url(_base_url: String, _model_name: String, _api_key: String, _stream: bool) -> String:
	var _url: String = _base_url.strip_edges()
	if _url.is_empty():
		return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
	
	# 没写 scheme 的情况下，兜底补 https://（否则 StreamRequest 解析会找不到 ://）
	if _url.find("://") == -1:
		_url = "https://" + _url
	
	# 去掉末尾所有 /
	while _url.ends_with("/"):
		_url = _url.substr(0, _url.length() - 1)
	
	# 用户已经填了完整 endpoint：原样返回
	if _url.find("/api/paas/v4/chat/completions") != -1:
		return _url
	
	# 用户填到 v4：补 chat/completions
	if _url.ends_with("/api/paas/v4"):
		return _url + "/chat/completions"
	
	# 用户填到 api/paas：补 v4/chat/completions
	if _url.ends_with("/api/paas"):
		return _url + "/v4/chat/completions"
	
	# 用户填了更深的路径但包含 api/paas/v4：截断到 v4 再补全
	var _idx_v4: int = _url.find("/api/paas/v4")
	if _idx_v4 != -1:
		var _prefix: String = _url.substr(0, _idx_v4 + "/api/paas/v4".length())
		return _prefix + "/chat/completions"
	
	# 用户填了更深的路径但包含 api/paas：截断到 api/paas 再补全
	var _idx_paas: int = _url.find("/api/paas")
	if _idx_paas != -1:
		var _prefix: String = _url.substr(0, _idx_paas + "/api/paas".length())
		return _prefix + "/v4/chat/completions"
	
	# 6) 用户只填域名（或其它）：直接从当前值后拼标准路径
	return _url + "/api/paas/v4/chat/completions"
