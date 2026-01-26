class_name ProviderFactory
extends RefCounted

## LLM Provider 工厂类
##
## 负责根据配置名称实例化对应的 LLM Provider。

# --- Public Functions ---

## 创建 Provider 实例
## [param p_provider_type]: Provider 类型名称
static func create_provider(p_provider_type: String) -> BaseLLMProvider:
	match p_provider_type:
		"OpenAI-Compatible":
			return BaseOpenAIProvider.new()
		"Local-AI-Service":
			return LocalAIProvider.new()
		"ZhipuAI":
			return ZhipuAIProvider.new()
		"Google Gemini":
			return GeminiProvider.new()
		_:
			push_error("[ProviderFactory] Unknown provider type: %s" % p_provider_type)
			return null
