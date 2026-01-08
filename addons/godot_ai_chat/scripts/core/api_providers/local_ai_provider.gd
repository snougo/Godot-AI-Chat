@tool
extends BaseOpenAIProvider
class_name LocalAIProvider

## 针对本地服务（LM Studio/Ollama）的提供商实现。

# --- Public Functions ---

## 返回该 Provider 使用的流式解析协议
func get_stream_parser_type() -> BaseLLMProvider.StreamParserType:
	return BaseLLMProvider.StreamParserType.LOCAL_SSE


# 针对本地服务（LM Studio/Ollama）构建请求体
# 这里可以根据本地服务的特殊报错进行针对性调整
func build_request_body(_model_name: String, _messages: Array[ChatMessage], _temperature: float, _stream: bool, _tool_definitions: Array = []) -> Dictionary:
	var body: Dictionary = super.build_request_body(_model_name, _messages, _temperature, _stream, _tool_definitions)
	
	return body


# 如果本地服务获取模型列表的路径不同，也可以在这里重写
# func get_request_url(...)
