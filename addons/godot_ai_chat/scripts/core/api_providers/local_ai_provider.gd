@tool
extends BaseOpenAIProvider
class_name LocalAIProvider

# 针对本地服务（LM Studio/Ollama）构建请求体
# 这里可以根据本地服务的特殊报错进行针对性调整
func build_request_body(_model_name: String, _messages: Array[ChatMessage], _temperature: float, _stream: bool, _tool_definitions: Array = []) -> Dictionary:
	var body = super.build_request_body(_model_name, _messages, _temperature, _stream, _tool_definitions)
	
	# 策略：如果发现本地服务在处理多模态或工具调用时报错，
	# 我们可以在这里对 body 进行二次加工。
	# 例如：某些本地服务不支持 stream_options 中的 include_usage
	if body.has("stream_options"):
		body.erase("stream_options")
	
	return body

# 如果本地服务获取模型列表的路径不同，也可以在这里重写
# func get_request_url(...)
