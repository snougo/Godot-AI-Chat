@tool
class_name SubAgentConfig
extends Resource

## Sub Agent 独立配置文件

@export_enum("OpenAI-ChatCompletions", "Anthropic-Compatible") var api_provider: String = "OpenAI-ChatCompletions"
@export var api_base_url: String = "http://127.0.0.1:1234"
@export var api_key: String = ""
@export var model_name: String = ""

@export_range(1, 100, 1) var max_chat_turns: int = 40
@export var network_timeout: int = 180
@export_range(0.0, 1.0, 0.1) var temperature: float = 0.6

@export_multiline var base_system_prompt: String = """你是一个专门的 `Sub-Agent` 。
你唯一的目的是使用提供的工具来执行分配的任务。
当你顺利完成任务或遇到错误导致无法完成任务时，你必须使用 'report_task_result' 工具进行任务报告。"""


## 获取单例配置（如果不存在则自动创建）
static func get_config() -> SubAgentConfig:
	var path: String = PluginPaths.PLUGIN_DIR + "sub_agent_config.tres"
	if ResourceLoader.exists(path):
		return ResourceLoader.load(path, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
	else:
		var config := SubAgentConfig.new()
		ResourceSaver.save(config, path)
		ToolBox.update_editor_filesystem(path)
		return config
