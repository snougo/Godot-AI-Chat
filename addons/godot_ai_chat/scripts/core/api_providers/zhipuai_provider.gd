@tool
extends BaseOpenAIProvider
class_name ZhipuAIProvider


# 智谱 V4 完美兼容 SSE
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


# 智谱 V4 的 URL 规则比较特殊，必须包含 /api/paas/v4
func get_request_url(base_url: String, _model_name: String, _api_key: String, _stream: bool) -> String:
	var url = base_url.strip_edges()
	
	if url.is_empty():
		return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
	
	# 容错处理：确保包含必要的路径片段
	if not url.contains("api/paas"):
		if not url.ends_with("/"): url += "/"
		url += "api/paas/"
	
	if not url.contains("v4/chat/completions"):
		if not url.ends_with("/"): url += "/"
		url += "v4/chat/completions"
	
	return url

# Header 和 Body 构建直接继承 BaseOpenAIProvider 即可
# 智谱 V4 支持标准的 "Authorization: Bearer <API_KEY>"
