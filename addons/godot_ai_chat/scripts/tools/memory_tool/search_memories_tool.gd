@tool
extends AiTool


func _init() -> void:
	tool_name = "search_memories"
	tool_description = "Search stored memories by workspace, keywords, memory type, and importance range. Keywords use fuzzy matching. Supports filtering by memory_type and importance range. workspace_path is required."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"workspace_path": {
				"type": "string",
				"description": "Filter by workspace path (required)"
			},
			"keywords": {
				"type": "string",
				"description": "Keywords to fuzzy search in title and content (optional — any word in the query will match)"
			},
			"limit": {
				"type": "integer",
				"minimum": 1,
				"maximum": 50,
				"default": 10,
				"description": "Maximum number of results (default 10, max 50)"
			},
			"sort_by": {
				"type": "string",
				"enum": ["default", "created_at", "last_accessed", "importance", "access_count"],
				"default": "default",
				"description": "Sort order: default (type→importance→time), created_at (newest first), last_accessed (recently viewed first), importance (highest first), access_count (most viewed first)"
			},
			"memory_type": {
				"type": "string",
				"enum": ["", "session_summary", "user_preference", "project_decision", "lesson_learned", "bug_fix"],
				"default": "",
				"description": "Filter by memory type (optional — empty string means no filter)"
			},
			"min_importance": {
				"type": "integer",
				"minimum": 1,
				"maximum": 5,
				"default": 1,
				"description": "Minimum importance filter (1-5, default 1)"
			},
			"max_importance": {
				"type": "integer",
				"minimum": 1,
				"maximum": 5,
				"default": 5,
				"description": "Maximum importance filter (1-5, default 5)"
			}
		},
		"required": ["workspace_path", "limit"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var workspace_path: String = p_args.get("workspace_path", "").strip_edges()
	var keywords: String = p_args.get("keywords", "").strip_edges()
	var limit: int = p_args.get("limit", 10)
	var sort_by: String = p_args.get("sort_by", "default")
	var memory_type: String = p_args.get("memory_type", "").strip_edges()
	var min_importance: int = p_args.get("min_importance", 1)
	var max_importance: int = p_args.get("max_importance", 5)
	
	if workspace_path.is_empty():
		return {"success": false, "data": "Error: workspace_path is required. Use the current workspace path from the system prompt."}
	
	limit = clampi(limit, 1, 50)
	min_importance = clampi(min_importance, 1, 5)
	max_importance = clampi(max_importance, 1, 5)
	if min_importance > max_importance:
		return {"success": false, "data": "Error: min_importance cannot be greater than max_importance."}
	
	var store := _load_or_create_store()
	var results := store.search(workspace_path, keywords, limit, sort_by, memory_type, min_importance, max_importance)
	
	if results.is_empty():
		return {"success": true, "data": "No memories found matching the criteria."}
	
	var lines: PackedStringArray = []
	lines.append("Found %d memories (showing top %d):" % [results.size(), limit])
	
	for i in range(results.size()):
		var entry: MemoryEntry = results[i]
		lines.append("")
		lines.append("[%d] %s" % [i + 1, entry.title])
		lines.append("    Workspace: %s" % entry.workspace_path)
		lines.append("    Type: %s | Importance: %d/5" % [entry.memory_type, entry.importance])
		lines.append("    Content: %s" % entry.content)
	
	# 保存更新后的访问计数
	store.save()
	
	return {"success": true, "data": "\n".join(lines)}


func _load_or_create_store() -> MemoryStore:
	if ResourceLoader.exists(MemoryStore.SAVE_PATH):
		return load(MemoryStore.SAVE_PATH) as MemoryStore
	
	var store := MemoryStore.new()
	store.save()
	return store
