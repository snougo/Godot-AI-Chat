@tool
class_name WebSearchTool
extends AiTool

## 执行在线搜索。
## 使用 HTTPClient 实现，无需节点挂载，无场景依赖。


const REQUEST_TIMEOUT: float = 30.0
const POLL_DELAY: float = 0.01  # 10ms


func _init() -> void:
	tool_name = "search_web"
	tool_description = "Performs an online search. Use ONLY when information is NOT available in local files or API docs."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"query": {
				"type": "string",
				"description": "The search query to find information about."
			}
		},
		"required": ["query"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var query: String = p_args.get("query", "")
	if query.is_empty():
		return {"success": false, "data": "Error: Query cannot be empty."}
	
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	var api_key: String = settings.tavily_api_key
	if api_key.is_empty():
		return {"success": false, "data": "Error: Tavily API Key is not configured."}
	
	return await _fetch_search_results(query, api_key)


# --- Private Functions ---

func _fetch_search_results(p_query: String, p_api_key: String) -> Dictionary:
	var client := HTTPClient.new()
	
	# 建立 TLS 连接
	var err := client.connect_to_host("api.tavily.com", 443, TLSOptions.client())
	if err != OK:
		client.close()
		return {"success": false, "data": "Error: Connection init failed (%d)" % err}
	
	# 等待连接握手
	var timer := 0.0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"success": false, "data": "Error: Connection timeout"}
	
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return {"success": false, "data": "Error: Connection failed (status: %d)" % client.get_status()}
	
	# 发送 POST 请求
	var body := JSON.stringify({
		"api_key": p_api_key,
		"query": p_query,
		"search_depth": "advanced",
		"include_answer": true,
		"max_results": 6
	})
	
	err = client.request(HTTPClient.METHOD_POST, "/search", ["Content-Type: application/json"], body)
	if err != OK:
		client.close()
		return {"success": false, "data": "Error: Request failed (%d)" % err}
	
	# 等待响应
	timer = 0.0
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
		timer += POLL_DELAY
		if timer >= REQUEST_TIMEOUT:
			client.close()
			return {"success": false, "data": "Error: Request timeout"}
	
	# 检查响应状态码
	if client.get_response_code() != 200:
		var code := client.get_response_code()
		client.close()
		return {"success": false, "data": "Error: HTTP %d" % code}
	
	# 读取响应体
	var response := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		response.append_array(client.read_response_body_chunk())
		if client.get_status() == HTTPClient.STATUS_BODY:
			await Engine.get_main_loop().create_timer(POLL_DELAY).timeout
	
	client.close()
	return _parse_response(response)


func _parse_response(p_data: PackedByteArray) -> Dictionary:
	var json := JSON.parse_string(p_data.get_string_from_utf8())
	if json == null:
		return {"success": false, "data": "Error: Invalid JSON response"}
	
	var output := ""
	if json.has("answer") and not str(json.answer).is_empty():
		output += "Direct Answer: " + str(json.answer) + "\n\n"
	
	if json.has("results") and json.results is Array:
		output += "Search Results:\n"
		for item in json.results:
			output += "- [%s](%s): %s\n" % [
				item.get("title", "No Title"),
				item.get("url", "#"),
				item.get("content", "")
			]
	
	return {"success": true, "data": output}
