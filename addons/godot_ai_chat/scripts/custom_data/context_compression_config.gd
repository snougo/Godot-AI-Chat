@tool
class_name ContextCompressionConfig
extends Resource

## 上下文压缩配置
##
## 用于配置上下文压缩功能使用的 LLM 模型参数。
## 当对话轮次超过 max_chat_turns 时，会自动触发压缩：
## 保留第一轮原始对话，将其余轮次送 LLM 进行摘要，
## 然后在新会话中拼接 [第一轮] + [摘要] 继续对话。

## 是否启用上下文压缩（关闭时自动触发路径回退为截断逻辑，手动压缩按钮也会被禁用）
@export var enabled: bool = false

## 摘要请求使用的 API 服务提供商类型
@export_enum("OpenAI-ChatCompletions", "OpenAI-Responses", "Anthropic-Compatible", "OpenCode Go") var api_provider: String = "OpenAI-ChatCompletions"

## API 服务的基地址。（必填，需以 http:// 或 https:// 开头；不再回退到主对话配置）
@export var api_base_url: String = ""

## API 密钥。（远程服务必填；本地/内网推理服务可留空）
@export var api_key: String = ""

## 摘要模型名称（建议使用快速、廉价的模型）
@export var model_name: String = ""

## 摘要请求的温度参数（建议较低温度以获得稳定输出）
@export_range(0.0, 2.0, 0.1) var temperature: float = 0.3

## 摘要请求的系统提示词
@export_multiline var summary_prompt: String = """## 设定
你是一位在Godot游戏引擎中工作的对话总结助手。

## 输出格式
总结内容分为以下两部分：

### 1. 核心概要
提取对后续对话有实际参考价值的关键信息：

- **用户目标**：用户想要达成什么目的？当前进度如何？
- **关键决策**：做了什么重要决定？依据是什么？
- **技术细节**：涉及的文件路径、API 调用、架构/设计变更
- **待办事项**：还有哪些未解决的问题、bug 或下一步任务

> 忽略无关寒暄、重复内容和无参考价值的元信息。

> 不要在输出中出现和总结内容无关的回复

### 2. 对话日志（精简）
按轮次记录对话过程，重点关注 AI 的操作行为：

```
第一轮：
用户：xxx
AI：xxx
  → 调用了 read_file（path: res://xxx.gd）
  → 返回了关键内容：xxx
  → 调用了 edit_scene（修改了 Camera2D 的 zoom 属性）

第二轮：
用户：xxx
AI：xxx
  → 调用了 search_godot_api（查询 TileMap 的 set_cell 方法）
  → 返回了方法签名
以此类推
```

工具调用的**入参和返回结果**是上下文的关键部分，应保留要点，避免大段拷贝原文。

> **注意**：如果收到的内容中已有上一轮的总结内容（以**[Previous Conversation Summary]**标记为开头的User信息），说明这不是第一次进行总结，你需要在**原总结基础上**：
> - **Part 1**：整合新旧内容并重写
> - **Part 2**：在原日志内容的基础上增量追加新轮次的内容

> **注意**：不得丢弃或忽略旧总结中的任何信息。
"""


# --- Validation ---

## 校验配置是否完整、格式是否合法
## [return] 空字符串表示有效；否则返回问题描述
func validate() -> String:
	var problems: PackedStringArray = []
	
	if api_provider.strip_edges().is_empty():
		problems.append("api_provider is empty")
	
	var url: String = api_base_url.strip_edges()
	if url.is_empty():
		problems.append("api_base_url is empty")
	elif not (url.begins_with("http://") or url.begins_with("https://")):
		problems.append("api_base_url is invalid (must start with http:// or https://)")
	elif _extract_host(url).is_empty():
		problems.append("api_base_url has no parsable host")
	
	if model_name.strip_edges().is_empty():
		problems.append("model_name is empty")
	
	# 本地/内网推理服务通常不做鉴权，仅远程服务才强制要求 api_key
	if not url.is_empty() and not is_local_service(url) and api_key.strip_edges().is_empty():
		problems.append("api_key is empty (required for remote services)")
	
	if problems.is_empty():
		return ""
	return "Configuration problems: " + "; ".join(problems)


## 判断 API 基地址是否指向本地/内网推理服务
## [desc] Ollama / LM Studio / llama.cpp / vLLM 等本地部署服务一般无效验，无需 api_key
static func is_local_service(p_base_url: String) -> bool:
	var host: String = _extract_host(p_base_url)
	if host.is_empty():
		return false
	
	# 回环地址
	if host == "localhost" or host == "::1" or host == "0.0.0.0":
		return true
	if host.begins_with("127."):
		return true
	
	# 私有网段（局域网内的自建推理服务）
	if host.begins_with("10.") or host.begins_with("192.168."):
		return true
	if host.begins_with("172."):
		var parts: PackedStringArray = host.split(".")
		if parts.size() >= 2 and parts[1].is_valid_int():
			var second: int = int(parts[1])
			if second >= 16 and second <= 31:
				return true
	
	return false


# --- Private Functions ---

# 从 URL 中提取主机名（剥离协议、路径、认证段、端口）
static func _extract_host(p_base_url: String) -> String:
	var s: String = p_base_url.strip_edges().to_lower()
	
	var scheme_idx: int = s.find("://")
	if scheme_idx != -1:
		s = s.substr(scheme_idx + 3)
	
	var path_idx: int = s.find("/")
	if path_idx != -1:
		s = s.substr(0, path_idx)
	
	var at_idx: int = s.rfind("@")
	if at_idx != -1:
		s = s.substr(at_idx + 1)
	
	# 带方括号的 IPv6（如 [::1]:11434）
	if s.begins_with("["):
		var close_idx: int = s.find("]")
		if close_idx != -1:
			return s.substr(1, close_idx - 1)
		return s
	
	# 裸 IPv6 无法区分端口，原样返回
	if s.count(":") > 1:
		return s
	
	var port_idx: int = s.rfind(":")
	if port_idx != -1:
		s = s.substr(0, port_idx)
	
	return s
