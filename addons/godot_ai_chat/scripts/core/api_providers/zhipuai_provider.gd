@tool
extends BaseOpenAIProvider
class_name ZhipuAIProvider

# 智谱AI支持的模型列表（硬编码，因为API不提供模型列表端点）
const ZHIPUAI_MODELS: Array[String] = ["glm-4.5", "glm-4.5-air"]


# 智谱 V4 完美兼容 SSE
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


# 获取模型列表URL（智谱AI不提供此端点，返回空字符串）
func get_model_list_url(_base_url: String) -> String:
	return ""  # 智谱AI不提供模型列表端点


# 重写模型列表解析 - 直接返回硬编码的模型列表
func parse_model_list_response(_body_bytes: PackedByteArray) -> Array[String]:
	# 智谱AI不支持模型列表API，直接返回硬编码列表
	return ZHIPUAI_MODELS


# 智谱 V4 的 URL 规则：固定为 /api/paas/v4/chat/completions
func get_request_url(base_url: String, _model_name: String, _api_key: String, _stream: bool) -> String:
	var url := base_url.strip_edges()
	if url.is_empty():
		return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
	
	# 没写 scheme 的情况下，兜底补 https://（否则 StreamRequest 解析会找不到 ://）
	if url.find("://") == -1:
		url = "https://" + url
	
	# 去掉末尾所有 /
	while url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	
	# 用户已经填了完整 endpoint：原样返回
	if url.find("/api/paas/v4/chat/completions") != -1:
		return url
	
	# 用户填到 v4：补 chat/completions
	if url.ends_with("/api/paas/v4"):
		return url + "/chat/completions"
	
	# 用户填到 api/paas：补 v4/chat/completions
	if url.ends_with("/api/paas"):
		return url + "/v4/chat/completions"
	
	# 用户填了更深的路径但包含 api/paas/v4：截断到 v4 再补全
	var idx_v4 := url.find("/api/paas/v4")
	if idx_v4 != -1:
		var prefix := url.substr(0, idx_v4 + "/api/paas/v4".length())
		return prefix + "/chat/completions"
	
	# 用户填了更深的路径但包含 api/paas：截断到 api/paas 再补全
	var idx_paas := url.find("/api/paas")
	if idx_paas != -1:
		var prefix := url.substr(0, idx_paas + "/api/paas".length())
		return prefix + "/v4/chat/completions"
	
	# 6) 用户只填域名（或其它）：直接从当前值后拼标准路径
	return url + "/api/paas/v4/chat/completions"
