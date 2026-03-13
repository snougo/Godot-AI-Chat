@tool
class_name AiNotebook
extends Resource

const SAVE_PATH: String = PluginPaths.PLUGIN_DIR + "ai_notebook.tres"

@export var notes: Array[AiNote] = []


## Get next available ID
func get_next_id() -> int:
	if notes.is_empty():
		return 1
	var max_id: int = 0
	for item in notes:
		if item.id > max_id:
			max_id = item.id
	return max_id + 1


## Add note
func add_note(p_title: String, p_content: String, p_category: String, p_importance: int = 3) -> AiNote:
	if not AiNote.is_valid_category(p_category):
		push_error("Invalid category: %s. Valid categories: %s" % [p_category, AiNote.get_valid_categories()])
		return null
	
	var item := AiNote.new()
	item.id = get_next_id()
	item.title = p_title
	item.content = p_content
	item.category = p_category
	item.importance = AiNote.clamp_importance(p_importance)
	
	notes.append(item)
	return item


## Search notes (by category and/or keywords)
## Sorted by: importance (desc) -> created_time (desc)
func search_notes(p_category: String = "", p_keywords: String = "", p_limit: int = 5) -> Array[AiNote]:
	var results: Array[AiNote] = []
	var keywords_lower: String = p_keywords.to_lower()
	
	for item in notes:
		var match_category: bool = p_category.is_empty() or item.category == p_category
		var match_keywords: bool = p_keywords.is_empty() or \
			item.title.to_lower().contains(keywords_lower) or \
			item.content.to_lower().contains(keywords_lower)
		
		if match_category and match_keywords:
			results.append(item)
	
	# Sort by importance (descending), then by created_time (descending)
	results.sort_custom(_compare_notes)
	
	if results.size() > p_limit:
		results = results.slice(0, p_limit)
	
	return results


## Custom comparison function for sorting
## Priority: importance (high -> low) -> created_time (new -> old)
func _compare_notes(a: AiNote, b: AiNote) -> bool:
	if a.importance != b.importance:
		return a.importance > b.importance
	# When importance is equal, newer notes come first
	return a.created_time > b.created_time


## Get all available categories
func get_all_categories() -> Array[String]:
	return AiNote.get_valid_categories()


## Get category statistics
## Returns: [{ "category": String, "count": int, "avg_importance": float, "high_importance_count": int }]
func get_category_statistics() -> Array[Dictionary]:
	var stats: Dictionary = {}
	
	# Initialize stats for all valid categories
	for cat in AiNote.get_valid_categories():
		stats[cat] = {
			"category": cat,
			"count": 0,
			"total_importance": 0,
			"high_importance_count": 0  # importance >= 4
		}
	
	# Calculate statistics
	for item in notes:
		if stats.has(item.category):
			stats[item.category].count += 1
			stats[item.category].total_importance += item.importance
			if item.importance >= 4:
				stats[item.category].high_importance_count += 1
	
	# Convert to array and calculate averages
	var result: Array[Dictionary] = []
	for cat in stats.keys():
		var stat: Dictionary = stats[cat]
		if stat.count > 0:
			stat.avg_importance = float(stat.total_importance) / stat.count
		else:
			stat.avg_importance = 0.0
		stat.erase("total_importance")  # Remove temporary field
		result.append(stat)
	
	return result


## Get high importance notes
func get_high_importance_notes(p_threshold: int = 4, p_limit: int = 10) -> Array[AiNote]:
	var results: Array[AiNote] = []
	for item in notes:
		if item.importance >= p_threshold:
			results.append(item)
	
	# Use the same comparison logic
	results.sort_custom(_compare_notes)
	
	if results.size() > p_limit:
		results = results.slice(0, p_limit)
	
	return results


## Save to disk
func save() -> Error:
	return ResourceSaver.save(self, SAVE_PATH)
