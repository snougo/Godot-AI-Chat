@tool
extends AiTool


func _init() -> void:
	tool_name = "search_memories"
	tool_description = "Search stored memories by workspace, memory type, and limit. Keywords are optional — when omitted, returns all entries matching the workspace and type. workspace_path is required."


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
				"description": "Keywords to fuzzy search in title and content (optional — leave empty to return all entries of the specified type)"
			},
			"memory_type": {
				"type": "string",
				"enum": MemoryEntry.get_valid_types(),
				"description": "Filter by memory type (required — must select one type)"
			},
			"limit": {
				"type": "integer",
				"minimum": 1,
				"maximum": 50,
				"default": 10,
				"description": "Maximum number of results (required, default 10, max 50)"
			}
		},
		"required": ["workspace_path", "memory_type", "limit"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var workspace_path: String = p_args.get("workspace_path", "").strip_edges()
	var keywords: String = p_args.get("keywords", "").strip_edges()
	var memory_type: String = p_args.get("memory_type", "").strip_edges()
	var limit: int = p_args.get("limit", 10)
	
	if workspace_path.is_empty():
		return {"success": false, "data": "Error: workspace_path is required. Use the current workspace path from the system prompt."}
	
	if memory_type.is_empty():
		return {"success": false, "data": "Error: memory_type is required. Select one type from: %s" % [", ".join(MemoryEntry.get_valid_types())]}
	
	if not MemoryEntry.is_valid_type(memory_type):
		return {
			"success": false,
			"data": "Error: Invalid memory type '%s'. Valid options: %s" % [memory_type, MemoryEntry.get_valid_types()]
		}
	
	limit = clampi(limit, 1, 50)
	
	var store := _load_or_create_store()
	var results := store.search(workspace_path, keywords, limit, memory_type)
	
	if results.is_empty():
		return {"success": true, "data": "No memories found matching the criteria."}
	
	var lines: PackedStringArray = []
	lines.append("Found %d memories (showing top %d):" % [results.size(), limit])
	
	for i in range(results.size()):
		var entry: MemoryEntry = results[i]
		lines.append("")
		lines.append("[%d] %s" % [i + 1, entry.title])
		lines.append("    Workspace: %s" % entry.workspace_path)
		lines.append("    Type: %s" % entry.memory_type)
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
