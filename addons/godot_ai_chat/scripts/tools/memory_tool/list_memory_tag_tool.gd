@tool
extends AiTool

func _init() -> void:
	tool_name = "list_memory_tags"
	tool_description = "List all existing memory tags with memory details."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(p_args: Dictionary) -> Dictionary:
	var archive := _load_or_create_archive()
	var tags := archive.get_all_tags()
	
	if tags.is_empty():
		return {"success": true, "data": "No memory tags found."}
	
	var result: String = "### All Memory Tags (%d found):\n\n" % tags.size()
	
	for tag in tags:
		var memories := archive.search_memories(tag, 999)
		result += "- **%s** (%d memories)\n" % [tag, memories.size()]
		for mem in memories:
			result += "  - %s\n" % mem.title
	
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
