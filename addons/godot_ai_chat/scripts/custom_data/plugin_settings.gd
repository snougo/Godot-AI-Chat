extends Resource
class_name PluginSettings

# 该脚本定义了一个自定义资源（Resource），用于存储和管理整个插件的所有用户可配置项。
# 通过 `@export` 相关的注解，这些变量会直接显示在 Godot 编辑器的检查器（Inspector）中，
# 允许用户方便地修改设置，并将结果保存到 "plugin_settings.tres" 文件中。


# API服务提供商类型。使用 `@export_enum` 可以在编辑器中提供一个下拉选择菜单。
@export_enum("OpenAI-Compatible", "Local-AI-Service", "ZhipuAI", "Google Gemini") var api_provider: String = "OpenAI-Compatible"
# API服务的基地址 (例如 "https://api.openai.com" 或本地模型的地址)。
@export var api_base_url: String = ""
# API密钥（可选，取决于服务提供商）。
@export var api_key: String = ""
# 在每次请求中发送给AI的上下文消息的需要被保留的最大对话轮数。
@export_range(1, 50, 1) var max_chat_turns: int = 8
# 网络流式输出请求的超时时间（秒）。
@export var network_timeout: int = 180
# AI模型的“温度”参数，控制生成文本的随机性和创造性。值越高越有创意，越低越确定。
@export_range(0.0, 1.0, 0.1) var temperature: float = 1.0
# 系统提示词（System Prompt），用于设定AI的角色和行为准则。
@export_multiline var system_prompt: String = "You are a helpful Godot Engine Assistant."
