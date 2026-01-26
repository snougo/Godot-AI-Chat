@tool
class_name LocalAIProvider
extends BaseOpenAIProvider

## 针对本地服务（LM Studio/Ollama）的提供商实现

# --- Public Functions ---

## 返回该 Provider 使用的流式解析协议
func get_stream_parser_type() -> StreamParserType:
	return StreamParserType.LOCAL_SSE


## 针对本地服务（LM Studio/Ollama）构建请求体
func build_request_body(p_model_name: String, p_messages: Array[ChatMessage], p_temperature: float, p_stream: bool, p_tool_definitions: Array = []) -> Dictionary:
	# 这里可以根据本地服务的特殊报错进行针对性调整，目前直接复用父类
	return super.build_request_body(p_model_name, p_messages, p_temperature, p_stream, p_tool_definitions)
