@tool
extends AiTool

func _init() -> void:
	tool_name = "search_memories"
	tool_description = "Search memories by tag."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"query": {
				"type": "string",
				"description": "Tag of memory item, used for memory retrieval"
			},
			"limit": {
				"type": "integer",
				"default": 5,
				"description": "Maximum number of results to return (default 5)"
			}
		},
		"required": ["query"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var query: String = p_args.get("query", "")
	var limit: int = p_args.get("limit", 5)
	
	if query.is_empty():
		return {"success": false, "data": "Search Tag is required."}
	
	var archive := _load_or_create_archive()
	var results := archive.search_memories(query, limit)
	
	if results.is_empty():
		return {"success": true, "data": "No memories found with tag: %s" % query}
	
	var lines: PackedStringArray = ["### Memory Search Results (%d found)" % results.size()]
	
	for memory in results:
		var tag_str: String = ", ".join(memory.tags) if not memory.tags.is_empty() else "None"
		lines.append("\nTitle: %s\n" % memory.title)
		lines.append("Created Time: %s\n" % memory.created_time)
		lines.append("Content:\n%s\n" % memory.content)
		lines.append("Tags: %s\n" % tag_str)
		lines.append("---")
	
	return {"success": true, "data": "\n".join(lines)}


func _load_or_create_archive() -> MemoryArchive:
	if ResourceLoader.exists(MemoryArchive.SAVE_PATH):
		return load(MemoryArchive.SAVE_PATH) as MemoryArchive
	
	var archive := MemoryArchive.new()
	archive.save()
	return archive
