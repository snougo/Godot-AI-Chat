class_name PluginSettings
extends Resource

## 插件设置数据类
##
## 存储和管理插件的所有用户可配置项。

# --- @export Vars ---

## API 服务提供商类型
@export_enum("OpenAI-Compatible", "LM Studio Stateful", "ZhipuAI", "Google Gemini", "Anthropic-Compatible") var api_provider: String = "OpenAI-Compatible"

## API 服务的基地址 (例如 "https://api.openai.com" 或本地模型的地址)
@export var api_base_url: String = ""

## API 密钥（可选，取决于服务提供商）
@export var api_key: String = ""

## 搜索引擎 Tavily 的密钥（可选）
@export var tavily_api_key: String = ""

## 每次请求中保留的最大对话轮数
@export_range(1, 50, 1) var max_chat_turns: int = 12

## 网络流式输出请求的超时时间（秒）
@export var network_timeout: int = 180

## AI 模型的“温度”参数，控制生成文本的随机性和创造性
@export_range(0.0, 1.0, 0.1) var temperature: float = 0.8

## 日志级别开关 (Bitmask: DEBUG=1, INFO=2, WARN=4, ERROR=8)
## 默认 14 (INFO|WARN|ERROR) = 2+4+8
@export_flags("Debug", "Info", "Warn", "Error") var log_flags: int = 8

## 系统提示词（System Prompt），用于设定 AI 的角色和行为准则
@export_multiline var system_prompt: String = "You are a helpful Godot Engine Assistant."
