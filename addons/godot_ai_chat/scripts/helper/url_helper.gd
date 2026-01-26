@tool
class_name URLHelper
extends RefCounted

## URL 辅助工具
##
## 用于处理和规范化 API 端点 URL 的工具类。

# --- Public Functions ---

## 规范化智谱 AI (ZhipuAI) 的 API 端点
## 能够处理用户输入的各种不完整或带有多余斜杠的 URL
static func normalize_zhipu_url(p_input_url: String) -> String:
	var url: String = p_input_url.strip_edges()
	
	# 1. 默认值兜底
	if url.is_empty():
		return "https://open.bigmodel.cn/api/paas/v4/chat/completions"
	
	# 2. 补全协议头
	if url.find("://") == -1:
		url = "https://" + url
	
	# 3. 去除末尾斜杠
	while url.ends_with("/"):
		url = url.substr(0, url.length() - 1)
	
	# 4. 智能补全路径
	# Case A: 已经是完整路径
	if url.find("/api/paas/v4/chat/completions") != -1:
		return url
	
	# Case B: 只有 v4
	if url.ends_with("/api/paas/v4"):
		return url + "/chat/completions"
	
	# Case C: 只有 paas
	if url.ends_with("/api/paas"):
		return url + "/v4/chat/completions"
	
	# Case D: 用户填了非标准长路径但包含部分关键字 (截断修复)
	var idx_v4: int = url.find("/api/paas/v4")
	if idx_v4 != -1:
		var prefix: String = url.substr(0, idx_v4 + "/api/paas/v4".length())
		return prefix + "/chat/completions"
	
	var idx_paas: int = url.find("/api/paas")
	if idx_paas != -1:
		var prefix: String = url.substr(0, idx_paas + "/api/paas".length())
		return prefix + "/v4/chat/completions"
	
	# Case E: 仅域名，直接拼接
	return url + "/api/paas/v4/chat/completions"
