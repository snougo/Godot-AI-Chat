@tool
extends AiTool


func _init() -> void:
	tool_name = "add_note"
	tool_description = "Add a new note to the Notebook with category and importance level."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"title": {
				"type": "string",
				"description": "Note title, max 20 characters"
			},
			"content": {
				"type": "string",
				"description": "Note content"
			},
			"category": {
				"type": "string",
				"enum": AiNote.get_valid_categories(),  # Use centralized categories
				"description": "Note category (required)"
			},
			"importance": {
				"type": "integer",
				"min": AiNote.MIN_IMPORTANCE,
				"max": AiNote.MAX_IMPORTANCE,
				"default": 3,
				"description": "Importance level (%d-%d)" % [AiNote.MIN_IMPORTANCE, AiNote.MAX_IMPORTANCE]
			}
		},
		"required": ["title", "content", "category", "importance"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var title: String = p_args.get("title", "")
	var content: String = p_args.get("content", "")
	var category: String = p_args.get("category", "")
	var importance: int = p_args.get("importance", 3)
	
	# Validation
	if title.is_empty() or content.is_empty() or category.is_empty():
		return {"success": false, "data": "Title, Content, and Category are required!"}
	
	if not AiNote.is_valid_category(category):
		return {
			"success": false, 
			"data": "Invalid category: %s. Valid options: %s" % [category, AiNote.get_valid_categories()]
		}
	
	# Clamp importance using centralized method
	importance = AiNote.clamp_importance(importance)
	
	var archive := _load_or_create_archive()
	var item := archive.add_note(title, content, category, importance)
	
	if not item:
		return {"success": false, "data": "Failed to add note."}
	
	var err := archive.save()
	if err != OK:
		return {"success": false, "data": "Failed to save note: %s" % error_string(err)}
	
	var result: String = "Note added successfully.\n"
	result += "Title: %s\n" % item.title
	result += "Category: %s\n" % item.category
	result += "Importance: %d/%d\n" % [item.importance, AiNote.MAX_IMPORTANCE]
	result += "Created: %s\n" % item.created_time
	result += "\nContent:\n%s" % item.content
	
	return {"success": true, "data": result}


func _load_or_create_archive() -> AiNotebook:
	if ResourceLoader.exists(AiNotebook.SAVE_PATH):
		return load(AiNotebook.SAVE_PATH) as AiNotebook
	
	var archive := AiNotebook.new()
	archive.save()
	return archive
