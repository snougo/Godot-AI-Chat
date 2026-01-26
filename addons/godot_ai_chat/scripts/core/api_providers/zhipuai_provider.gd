@tool
class_name ZhipuAIProvider
extends BaseOpenAIProvider

## 智谱 AI (ZhipuAI) 的服务提供商实现

# --- Constants ---

## 智谱AI支持的模型列表
const ZHIPUAI_MODELS: Array[String] = ["glm-4.5-air"]

# --- Public Functions ---

## 智谱 V4 完美兼容 SSE
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.SSE


## 获取模型列表URL（智谱AI不提供此端点，返回空字符串）
func get_model_list_url(_p_base_url: String) -> String:
	return ""


## 重写模型列表解析 - 直接返回硬编码的模型列表
func parse_model_list_response(_p_body_bytes: PackedByteArray) -> Array[String]:
	return ZHIPUAI_MODELS


## 智谱 V4 的 URL 规则：固定为 /api/paas/v4/chat/completions
func get_request_url(p_base_url: String, _p_model_name: String, _p_api_key: String, _p_stream: bool) -> String:
	return URLHelper.normalize_zhipu_url(p_base_url)
