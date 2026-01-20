@tool
class_name URLHelper
extends RefCounted

## 用于处理和规范化 API 端点 URL 的工具类。

## 规范化智谱 AI (ZhipuAI) 的 API 端点
## 能够处理用户输入的各种不完整或带有多余斜杠的 URL
static func normalize_zhipu_url(_input_url: String) -> String:
	var _url: String = _input_url.strip_edges()
	
	# 1. 默认值兜底
	if _url.is_empty():
		return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
	
	# 2. 补全协议头
	if _url.find("://") == -1:
		_url = "https://" + _url
	
	# 3. 去除末尾斜杠
	while _url.ends_with("/"):
		_url = _url.substr(0, _url.length() - 1)
	
	# 4. 智能补全路径
	# Case A: 已经是完整路径
	if _url.find("/api/paas/v4/chat/completions") != -1:
		return _url
	
	# Case B: 只有 v4
	if _url.ends_with("/api/paas/v4"):
		return _url + "/chat/completions"
	
	# Case C: 只有 paas
	if _url.ends_with("/api/paas"):
		return _url + "/v4/chat/completions"
	
	# Case D: 用户填了非标准长路径但包含部分关键字 (截断修复)
	var _idx_v4: int = _url.find("/api/paas/v4")
	if _idx_v4 != -1:
		var _prefix: String = _url.substr(0, _idx_v4 + "/api/paas/v4".length())
		return _prefix + "/chat/completions"
	
	var _idx_paas: int = _url.find("/api/paas")
	if _idx_paas != -1:
		var _prefix: String = _url.substr(0, _idx_paas + "/api/paas".length())
		return _prefix + "/v4/chat/completions"
	
	# Case E: 仅域名，直接拼接
	return _url + "/api/paas/v4/chat/completions"
