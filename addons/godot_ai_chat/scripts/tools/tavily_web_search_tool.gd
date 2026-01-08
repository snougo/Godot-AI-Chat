@tool
extends AiTool

func _init():
	name = "tavily_web_search"
	description = "Search the internet for real-time information using Tavily API. Use this when you need up-to-date knowledge."

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

func execute(_args: Dictionary, _context_provider: Object) -> Dictionary:
	var query = _args.get("query", "")
	if query.is_empty():
		return {"success": false, "data": "Error: Query cannot be empty."}
	
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	var api_key = settings.get("tavily_api_key")
	
	if api_key == null or api_key.is_empty():
		return {"success": false, "data": "Error: Tavily API Key is not configured in settings."}
	
	# 创建临时的 HTTP 请求节点
	var http := HTTPRequest.new()
	# 添加到场景树根节点以确保其能运行
	Engine.get_main_loop().root.add_child(http)
	
	var url := "https://api.tavily.com/search"
	var headers := ["Content-Type: application/json"]
	var body := JSON.stringify({
		"api_key": api_key,
		"query": query,
		"search_depth": "basic",
		"include_answer": true,
		"max_results": 3
	})
	
	var err: Error = http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {"success": false, "data": "Error: Failed to send HTTP request."}
	
	# 等待请求完成 (异步)
	var response = await http.request_completed
	var result_body = response[3] # Body is at index 3
	var response_code = response[1]
	
	http.queue_free() # 清理节点
	
	if response_code != 200:
		return {"success": false, "data": "Error: Tavily API returned code %d" % response_code}
	
	var json = JSON.parse_string(result_body.get_string_from_utf8())
	if json == null:
		return {"success": false, "data": "Error: Failed to parse JSON response."}
	
	# 提取有用信息
	var output = ""
	if json.has("answer") and not str(json.answer).is_empty():
		output += "Direct Answer: " + str(json.answer) + "\n\n"
	
	if json.has("results") and json.results is Array:
		output += "Search Results:\n"
		for item in json.results:
			output += "- [%s](%s): %s\n" % [item.get("title", "No Title"), item.get("url", "#"), item.get("content", "")]
	
	return {"success": true, "data": output}
