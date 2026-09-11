class_name ProviderFactory
extends RefCounted

## LLM Provider 工厂类
##
## 负责根据配置名称实例化对应的 LLM Provider。
## PROVIDER_TYPES 是 Provider 类型名的唯一对外来源，UI 下拉框应直接使用它，
## 避免「工厂」与「设置面板」两处字面量各自漂移。


# --- Constants ---

## 全部可用的 Provider 类型名（顺序即设置面板下拉框的展示顺序）
const PROVIDER_TYPES: Array[String] = [
	"OpenAI-ChatCompletions",
	"OpenAI-Responses",
	"OpenCode Go",
	"ZhipuAI",
	"Google Gemini",
	"Anthropic-Compatible",
]


# --- Public Functions ---

## 创建 Provider 实例
## [param p_provider_type]: Provider 类型名称（取自 PROVIDER_TYPES）
static func create_provider(p_provider_type: String) -> BaseLLMProvider:
	match p_provider_type:
		"OpenAI-ChatCompletions":
			return OpenAIChatCompletionsProvider.new()
		"OpenAI-Responses":
			return OpenAIResponsesProvider.new()
		"OpenCode Go":
			return OpenCodeGoProvider.new()
		"ZhipuAI":
			return ZhipuAIProvider.new()
		"Google Gemini":
			return GeminiProvider.new()
		"Anthropic-Compatible":
			return AnthropicCompatibleProvider.new()
		_:
			AIChatLogger.error("[ProviderFactory] Unknown provider type: %s" % p_provider_type)
			return null
