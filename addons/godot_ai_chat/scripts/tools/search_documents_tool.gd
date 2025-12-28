extends AiTool


func _init():
	name = "search_documents"
	description = "Search for documentation files (markdown) by filename keywords. Use this to locate relevant documentation in the 'res://godot_doc' folder or other specified paths."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"keywords": {
				"type": "string",
				"description": "The keyword(s) to search for in filenames."
			},
			"path": {
				"type": "string",
				"description": "The folder path to search in. Defaults to 'res://godot_doc' if not specified."
			}
		},
		"required": ["keywords"]
	}


func execute(args: Dictionary, context_provider: ContextProvider) -> Dictionary:
	var keywords = args.get("keywords", "")
	var path = args.get("path", "res://godot_doc")
	
	# 简单的容错处理
	if keywords is Array:
		keywords = " ".join(keywords)
	elif not keywords is String:
		keywords = str(keywords)
		
	if keywords.is_empty():
		return {"success": false, "data": "Missing parameters: keywords"}
	
	# 调用 ContextProvider 的搜索方法
	if context_provider.has_method("search_files_as_markdown"):
		return context_provider.search_files_as_markdown(path, keywords, ".md")
	else:
		return {"success": false, "data": "Internal Error: ContextProvider does not support search."}
