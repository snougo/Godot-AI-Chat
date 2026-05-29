@tool
extends AiTool


func _init() -> void:
	tool_name = "add_memory"
	tool_description = "Store an important memory that the AI should remember for future conversations. Use this when the user shares preferences, makes project decisions, or discusses key information. Always provide the current workspace path. Use 'scope' to indicate whether this memory is workspace-level (only relevant to current module) or global (relevant to the entire project)."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"workspace_path": {
				"type": "string",
				"description": "The current workspace path. For global memories, use 'res://'."
			},
			"scope": {
				"type": "string",
				"enum": MemoryEntry.get_valid_scopes(),
				"description": "Memory scope: 'workspace' (only relevant to this module) or 'global' (relevant to the entire project)"
			},
			"title": {
				"type": "string",
				"description": "Memory title, max 50 characters"
			},
			"content": {
				"type": "string",
				"description": "Detailed memory content"
			},
			"memory_type": {
				"type": "string",
				"enum": MemoryEntry.get_valid_types(),
				"description": "Type of memory: session_summary, user_preference, project_decision, lesson_learned, bug_fix"
			}
		},
		"required": ["workspace_path", "scope", "title", "content", "memory_type"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var workspace_path: String = p_args.get("workspace_path", "").strip_edges()
	var scope: String = p_args.get("scope", "").strip_edges()
	var title: String = p_args.get("title", "").strip_edges()
	var content: String = p_args.get("content", "").strip_edges()
	var memory_type: String = p_args.get("memory_type", "")
	
	# Validation
	if workspace_path.is_empty():
		return {"success": false, "data": "Error: workspace_path is required. Use the current workspace path from the system prompt."}
	
	if scope.is_empty():
		return {"success": false, "data": "Error: scope is required. Use 'workspace' for module-level or 'global' for project-level memories."}
	
	if not MemoryEntry.is_valid_scope(scope):
		return {
			"success": false,
			"data": "Error: Invalid scope '%s'. Valid options: %s" % [scope, MemoryEntry.get_valid_scopes()]
		}
	
	if title.is_empty() or content.is_empty() or memory_type.is_empty():
		return {"success": false, "data": "Error: Title, Content, and Memory Type are required!"}
	
	if not MemoryEntry.is_valid_type(memory_type):
		return {
			"success": false,
			"data": "Error: Invalid memory type '%s'. Valid options: %s" % [memory_type, MemoryEntry.get_valid_types()]
		}
	
	var store := _load_or_create_store()
	var entry := store.add_entry(title, content, memory_type, scope, workspace_path)
	
	if not entry:
		return {"success": false, "data": "Error: Failed to add memory entry."}
	
	var err := store.save()
	if err != OK:
		return {"success": false, "data": "Error: Failed to save memory store: %s" % error_string(err)}
	
	var result: String = "Memory stored successfully.\n"
	result += "Scope: %s\n" % entry.scope
	result += "Workspace: %s\n" % entry.workspace_path
	result += "Title: %s\n" % entry.title
	result += "Type: %s\n" % entry.memory_type
	result += "Content: %s" % entry.content
	
	return {"success": true, "data": result}


func _load_or_create_store() -> MemoryStore:
	if ResourceLoader.exists(MemoryStore.SAVE_PATH):
		return load(MemoryStore.SAVE_PATH) as MemoryStore
	
	var store := MemoryStore.new()
	store.save()
	return store
