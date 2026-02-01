@tool
class_name WebSearchTool
extends AiTool

## 执行在线搜索。
## 仅在本地文件或 API 文档中无法找到信息时使用。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "search_web"
	tool_description = "Performs an online search. Use ONLY when information is NOT available in local files or API docs."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
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


## 执行网络搜索操作
## [param p_args]: 包含 query 的参数字典
## [return]: 搜索结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var query: String = p_args.get("query", "")
	
	if query.is_empty():
		return {"success": false, "data": "Error: Query cannot be empty."}
	
	var settings: PluginSettings = ToolBox.get_plugin_settings()
	var api_key: String = settings.get("tavily_api_key")
	
	var validation_result: Dictionary = _validate_api_key(api_key)
	if not validation_result.get("success", false):
		return validation_result
	
	return await _perform_web_search(query, api_key)


# --- Private Functions ---

## 验证 API 密钥
## [param p_api_key]: API 密钥
## [return]: 验证结果字典
func _validate_api_key(p_api_key: String) -> Dictionary:
	if p_api_key == null or p_api_key.is_empty():
		return {"success": false, "data": "Error: Tavily API Key is not configured in settings."}
	return {"success": true}


## 执行网络搜索
## [param p_query]: 搜索查询
## [param p_api_key]: API 密钥
## [return]: 搜索结果字典
func _perform_web_search(p_query: String, p_api_key: String) -> Dictionary:
	var http := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(http)
	
	var url: String = "https://api.tavily.com/search"
	var headers: PackedStringArray = ["Content-Type: application/json"]
	var body: String = JSON.stringify({
		"api_key": p_api_key,
		"query": p_query,
		"search_depth": "basic",
		"include_answer": true,
		"max_results": 6
	})
	
	var err: Error = http.request(url, headers, HTTPClient.METHOD_POST, body)
	if err != OK:
		http.queue_free()
		return {"success": false, "data": "Error: Failed to send HTTP request."}
	
	var response: Array = await http.request_completed
	var result_body: PackedByteArray = response[3]
	var response_code: int = response[1]
	
	http.queue_free()
	
	if response_code != 200:
		return {"success": false, "data": "Error: Tavily API returned code %d" % response_code}
	
	return _parse_search_response(result_body)


## 解析搜索响应
## [param p_result_body]: 响应体
## [return]: 解析结果字典
func _parse_search_response(p_result_body: PackedByteArray) -> Dictionary:
	var json = JSON.parse_string(p_result_body.get_string_from_utf8())
	if json == null:
		return {"success": false, "data": "Error: Failed to parse JSON response."}
	
	var output: String = _format_search_results(json)
	
	return {"success": true, "data": output}


## 格式化搜索结果
## [param p_json]: JSON 响应数据
## [return]: 格式化结果字符串
func _format_search_results(p_json: Dictionary) -> String:
	var output: String = ""
	
	if p_json.has("answer") and not str(p_json.answer).is_empty():
		output += "Direct Answer: " + str(p_json.answer) + "\n\n"
	
	if p_json.has("results") and p_json.results is Array:
		output += "Search Results:\n"
		for item in p_json.results:
			output += "- [%s](%s): %s\n" % [item.get("title", "No Title"), item.get("url", "#"), item.get("content", "")]
	
	return output
