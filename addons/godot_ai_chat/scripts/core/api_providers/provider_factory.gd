class_name ProviderFactory
extends RefCounted

## 负责根据配置名称实例化对应的 LLM Provider
## 遵循简单工厂模式，集中管理 Provider 的创建逻辑
static func create_provider(provider_type: String) -> BaseLLMProvider:
	match provider_type:
		"OpenAI-Compatible":
			return BaseOpenAIProvider.new()
		"Local-AI-Service":
			return LocalAIProvider.new()
		"ZhipuAI":
			return ZhipuAIProvider.new()
		"Google Gemini":
			return GeminiProvider.new()
		_:
			push_error("[ProviderFactory] Unknown provider type: %s" % provider_type)
			return null
