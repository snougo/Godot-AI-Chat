@tool
extends AiTool

## Search the Shader Library cache database for shaders.
## Filter by title keyword, shader type, and license.
## Supports sorting by likes, date, or alphabetically.

const CACHE_FILE_PATH: String = "user://shader_library_cache/shaders.json"


func _init() -> void:
	tool_name = "search_shader_library"
	tool_description = "Search the Shader Library cache database for shaders."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"query": {
				"type": "string",
				"description": "Keyword to fuzzy-match against shader titles. Required. Example: 'glitch', 'neon', 'water'."
			},
			"category": {
				"type": "string",
				"description": "Filter by shader type: canvas_item, spatial, particles, sky, fog.",
				"enum": ["canvas_item", "spatial", "particles", "sky", "fog"]
			},
			"license": {
				"type": "string",
				"description": "Filter by license: MIT, CC0, Shadertoy port, GNU GPL v.3.",
				"enum": ["MIT", "CC0", "Shadertoy port", "GNU GPL v.3"]
			},
			"sort_by": {
				"type": "string",
				"description": "Sort order for results.",
				"enum": ["likes", "newest", "alphabetical"],
				"default": "likes"
			},
			"limit": {
				"type": "integer",
				"description": "Maximum number of results to return (1~30).",
				"default": 10,
				"minimum": 1,
				"maximum": 30
			}
		},
		"required": ["query", "limit"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	# 1. Read cache file
	if not FileAccess.file_exists(CACHE_FILE_PATH):
		return {"success": false, "data": "Shader Library cache not found. Open the ShaderLib tab in the editor first to load the cache."}
	
	var file := FileAccess.open(CACHE_FILE_PATH, FileAccess.READ)
	if file == null:
		return {"success": false, "data": "Failed to open Shader Library cache file."}
	
	var json_str: String = file.get_as_text()
	file.close()
	
	var parsed = JSON.parse_string(json_str)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"success": false, "data": "Invalid cache file format."}
	
	var all_shaders: Array = parsed.get("shaders", [])
	if all_shaders.is_empty():
		return {"success": false, "data": "No shaders found in cache."}
	
	# 2. Extract parameters
	var query: String = p_args.get("query", "").strip_edges().to_lower()
	var category: String = p_args.get("category", "").strip_edges().to_lower()
	var license_filter: String = p_args.get("license", "").strip_edges()
	var sort_by: String = p_args.get("sort_by", "likes")
	var limit: int = clampi(p_args.get("limit", 10), 1, 30)
	
	# 3. Filter
	var filtered: Array = []
	for s in all_shaders:
		var title: String = s.get("title", "")
		var cat: String = s.get("category", "").to_lower()
		var lic: String = s.get("license", "")
		
		if query not in title.to_lower():
			continue
		if not category.is_empty() and cat != category:
			continue
		if not license_filter.is_empty() and lic != license_filter:
			continue
		
		filtered.append(s)
	
	if filtered.is_empty():
		return {"success": true, "data": "No matching shaders found."}
	
	# 4. Sort
	match sort_by:
		"newest":
			filtered.sort_custom(func(a, b): return a.get("date", "") > b.get("date", ""))
		"alphabetical":
			filtered.sort_custom(func(a, b): return a.get("title", "").to_lower() < b.get("title", "").to_lower())
		_:  # likes (default)
			filtered.sort_custom(func(a, b): return int(a.get("likes", 0)) > int(b.get("likes", 0)))
	
	# 5. Trim to limit
	var results: Array = filtered.slice(0, limit)
	
	# 6. Format output
	var lines: Array[String] = []
	lines.append("Found %d matching shaders (showing top %d):" % [filtered.size(), results.size()])
	lines.append("")
	
	for i in results.size():
		var s: Dictionary = results[i]
		var tags_str: String = ""
		var tags: Array = s.get("tags", [])
		if not tags.is_empty():
			tags_str = "  [Tags: %s]" % ", ".join(tags)
		
		lines.append("%d. **%s**" % [i + 1, s.get("title", "Untitled")])
		lines.append("   Author: %s  |  Type: %s  |  License: %s  |  Likes: %s" % [
			s.get("author", "Unknown"),
			s.get("category", "Unknown"),
			s.get("license", "Unknown"),
			str(s.get("likes", 0))
		])
		lines.append("   URL: %s%s" % [s.get("url", ""), tags_str])
		lines.append("")
	
	return {"success": true, "data": "\n".join(lines).strip_edges()}
