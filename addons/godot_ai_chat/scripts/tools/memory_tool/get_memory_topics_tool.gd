@tool
extends AiTool


func _init() -> void:
	tool_name = "get_memory_topics"
	tool_description = "Get all existing memory topic groups in the current workspace. Use this before adding a memory to see what topics already exist, or before searching to pick a topic."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"workspace_path": {
				"type": "string",
				"description": "The workspace path to query topics for (required)"
			}
		},
		"required": ["workspace_path"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var workspace_path: String = p_args.get("workspace_path", "").strip_edges()
	
	if workspace_path.is_empty():
		return {"success": false, "data": "Error: workspace_path is required."}
	
	var store := _load_or_create_store()
	var topics := store.get_topics(workspace_path)
	
	if topics.is_empty():
		return {"success": true, "data": "No topics found in this workspace."}
	
	var lines: PackedStringArray = []
	lines.append("Found %d topic(s) in workspace '%s':" % [topics.size(), workspace_path])
	for t in topics:
		lines.append("  - %s" % t)
	
	return {"success": true, "data": "\n".join(lines)}


func _load_or_create_store() -> MemoryStore:
	if ResourceLoader.exists(MemoryStore.SAVE_PATH):
		return load(MemoryStore.SAVE_PATH) as MemoryStore
	
	var store := MemoryStore.new()
	store.save()
	return store
