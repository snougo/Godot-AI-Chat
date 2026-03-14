@tool
extends AiTool


func _init() -> void:
	tool_name = "search_notes"
	tool_description = "Search Notebook content by category and keywords. Results are sorted by importance (high to low), then by creation time (new to old)."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"category": {
				"type": "string",
				"enum": AiNote.get_valid_categories(),
				"description": "Note category to filter by"
			},
			"keywords": {
				"type": "string",
				"description": "Keywords to search in title and content (case-insensitive)"
			},
			"limit": {
				"type": "integer",
				"minimum": 1,
				"maximum": 50,
				"default": 5,
				"description": "Maximum number of results to return (default 5, max 50)"
			}
		},
		"required": ["category", "keywords"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var category: String = p_args.get("category", "")
	var keywords: String = p_args.get("keywords", "")
	var limit: int = p_args.get("limit", 5)
	
	# Clamp limit to valid range
	limit = clampi(limit, 1, 50)
	
	var archive := _load_or_create_archive()
	var results := archive.search_notes(category, keywords, limit)
	
	if results.is_empty():
		return {"success": true, "data": "No notes found matching the criteria."}
	
	var lines: PackedStringArray = ["### Note Search Results (%d found, showing top %d)" % [results.size(), limit]]
	
	for i in range(results.size()):
		var note: AiNote = results[i]
		lines.append("\n")
		lines.append("[%d] Title: %s" % [i + 1, note.title])
		lines.append("    Category: %s" % note.category)
		lines.append("    Importance: %d/%d" % [note.importance, AiNote.MAX_IMPORTANCE])
		lines.append("    Created: %s" % note.created_time)
		lines.append("    Content:\n    %s" % note.content.replace("\n", "\n    "))
		lines.append("---")
	
	return {"success": true, "data": "\n".join(lines)}


func _load_or_create_archive() -> AiNotebook:
	if ResourceLoader.exists(AiNotebook.SAVE_PATH):
		return load(AiNotebook.SAVE_PATH) as AiNotebook
	
	var archive := AiNotebook.new()
	archive.save()
	return archive
