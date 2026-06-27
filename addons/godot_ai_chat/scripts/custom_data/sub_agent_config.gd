@tool
class_name SubAgentConfig
extends Resource

## Sub Agent 独立配置文件

@export_enum("OpenAI-ChatCompletions", "Anthropic-Compatible") var api_provider: String = "OpenAI-ChatCompletions"
@export var api_base_url: String = ""
@export var api_key: String = ""
@export var model_name: String = ""
@export var supports_vision: bool = false

@export_range(1, 100, 1) var max_chat_turns: int = 40
@export var network_timeout: int = 180
@export_range(0.0, 1.0, 0.1) var temperature: float = 0.6

@export_multiline var base_system_prompt: String = """##设定
你是一个技能专精的**Sub-Agent**，用于执行特定目的的任务。

##职责
完成**Main-Agent**分配的任务

## 核心原则
- 请严格遵守 `SKILL INSTRUCTION` 中的指令。
- 仔细阅读任务描述，理解你要做什么。
- 如果工具调用失败，尝试重试，如果尝试2次后都失败，直接放弃当前任务。
- 无论任务成功与否，都调用 `report_task_result` 工具进行任务报告。

---
"""


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
