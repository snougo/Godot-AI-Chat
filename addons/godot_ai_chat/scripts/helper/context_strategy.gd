@tool
class_name ContextStrategy
extends RefCounted

## 上下文构建策略基类
##
## 定义了不同 API 端点类型（有状态/无状态）的上下文构建接口。


## 构建上下文
## [param p_history]: 完整聊天记录
## [param p_settings]: 插件设置
## [param p_metadata]: 额外元数据（如 previous_response_id, is_first_request 等）
## [return]: 准备发送给 API 的 ChatMessage 数组
func build_context(p_history: ChatMessageHistory, p_settings: PluginSettingsConfig, p_metadata: Dictionary = {}) -> Array[ChatMessage]:
	return []
