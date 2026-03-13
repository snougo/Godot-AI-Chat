@tool
class_name SubAgentConfig
extends Resource

## Sub Agent 独立配置文件

@export_enum("LM Studio Stateful", "OpenAI-Compatible", "ZhipuAI", "Google Gemini", "Anthropic-Compatible") var api_provider: String = "OpenAI-Compatible"
@export var api_base_url: String = "http://127.0.0.1:1234"
@export var api_key: String = ""
@export var model_name: String = ""

@export_range(1, 100, 1) var max_chat_turns: int = 40
@export var network_timeout: int = 180
@export_range(0.0, 1.0, 0.1) var temperature: float = 0.6

@export_multiline var base_system_prompt: String = """You are a specialized Sub Agent. 
Your sole purpose is to execute the assigned task using the provided tools. 
You MUST use the 'report_task_result' tool when you have finished or if you encounter an unrecoverable error."""


## 获取单例配置（如果不存在则自动创建）
static func get_config() -> SubAgentConfig:
	var path = PluginPaths.PLUGIN_DIR + "sub_agent_config.tres"
	if ResourceLoader.exists(path):
		return ResourceLoader.load(path, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
	else:
		var config = SubAgentConfig.new()
		ResourceSaver.save(config, path)
		ToolBox.update_editor_filesystem(path)
		return config
