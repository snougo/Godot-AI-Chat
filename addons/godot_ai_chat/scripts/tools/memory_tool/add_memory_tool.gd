@tool
extends AiTool

func _init() -> void:
	tool_name = "add_memory"
	tool_description = "Add a new memory to the MemoryArchive."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"title": {
				"type": "string",
				"description": "Memory title, max 20 characters"
			},
			"content": {
				"type": "string",
				"description": "Memory content"
			},
			"tags": {
				"type": "array",
				"items": {"type": "string"},
				"description": "Memory tags for search"
			}
		},
		"required": ["title", "content", "tags"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var title: String = p_args.get("title", "")
	var content: String = p_args.get("content", "")
	
	var raw_tags: Array = p_args.get("tags", [])
	var tags: Array[String] = []
	for tag in raw_tags:
		var tag_str: String = str(tag).strip_edges()
		if not tag_str.is_empty():
			tags.append(tag_str)
	
	if title.is_empty() or content.is_empty():
		return {"success": false, "data": "Title and Content are Required!"}
	
	# 标题长度校验
	if title.length() > 30:
		return {"success": false, "data": "Memory addition failed, Title too long，Please keep the title under 20 characters."}
	
	var archive := _load_or_create_archive()
	var item := archive.add_memory(title, content, tags)
	
	var err := archive.save()
	if err != OK:
		return {"success": false, "data": "Failed to save memory: %s" % error_string(err)}
	
	var tag_str: String = ", ".join(item.tags) if not item.tags.is_empty() else "None"
	var result: String = "Memory added successfully.\nTitle: %s\n\nContent:\n%s\n\nTags: %s" % [item.title, item.content, tag_str]
	
	return {
		"success": true,
		"data": result
	}


func _load_or_create_archive() -> MemoryArchive:
	if ResourceLoader.exists(MemoryArchive.SAVE_PATH):
		return load(MemoryArchive.SAVE_PATH) as MemoryArchive
	
	var archive := MemoryArchive.new()
	archive.save()
	return archive
