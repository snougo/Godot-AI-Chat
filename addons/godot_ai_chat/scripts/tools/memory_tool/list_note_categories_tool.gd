@tool
extends AiTool


func _init() -> void:
	tool_name = "list_note_categories"
	tool_description = "List all available Note categories with usage statistics and note titles."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(p_args: Dictionary) -> Dictionary:
	var archive := _load_or_create_archive()
	var stats := archive.get_category_statistics()
	var total_notes: int = archive.notes.size()
	
	var lines: PackedStringArray = ["### Notebook Archive Statistics", ""]
	lines.append("Total notes: %d" % total_notes)
	lines.append("")
	
	if stats.is_empty():
		lines.append("No note statistics available.")
		return {"success": true, "data": "\n".join(lines)}
	
	# 按分类展示统计信息和笔记标题
	for stat in stats:
		var category: String = stat.category
		var count: int = stat.count
		
		lines.append("## %s" % category)
		lines.append("- Count: %d | Avg Importance: %.1f | High Priority: %d" % [
			count,
			stat.avg_importance,
			stat.high_importance_count
		])
		
		# 获取该分类下的所有笔记标题
		if count > 0:
			var category_notes := archive.search_notes(category, "", 50)
			var titles: PackedStringArray = []
			for note in category_notes:
				titles.append("  - %s (Importance: %d)" % [note.title, note.importance])
			lines.append("Notes:")
			lines.append("\n".join(titles))
		
		lines.append("")  # 空行分隔
	
	return {"success": true, "data": "\n".join(lines)}


func _load_or_create_archive() -> AiNotebook:
	if ResourceLoader.exists(AiNotebook.SAVE_PATH):
		return load(AiNotebook.SAVE_PATH) as AiNotebook
	
	var archive := AiNotebook.new()
	archive.save()
	return archive
