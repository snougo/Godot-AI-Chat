@tool
extends AiTool


func _init() -> void:
	tool_name = "add_memory"
	tool_description = "Store an important memory that the AI should remember for future conversations. Use 'topic' to group related memories under a common topic name."


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
				"description": "Memory scope: 'workspace' or 'global'"
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
				"description": "Type of memory: lesson_learned (principles + bug symptom/root-cause clues), design_rationale (why/architecture tradeoffs), user_preference (user preferences)"
			},
			"topic": {
				"type": "string",
				"description": "Topic group for this memory (required)."
			}
		},
		"required": ["workspace_path", "scope", "title", "content", "memory_type", "topic"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var workspace_path: String = p_args.get("workspace_path", "").strip_edges()
	var scope: String = p_args.get("scope", "").strip_edges()
	var title: String = p_args.get("title", "").strip_edges()
	var content: String = p_args.get("content", "").strip_edges()
	var memory_type: String = p_args.get("memory_type", "")
	var topic: String = p_args.get("topic", "").strip_edges()
	
	# Validation
	if workspace_path.is_empty():
		return ToolResult.fail("Error: workspace_path is required. Use the current workspace path from the system prompt.")
	
	if scope.is_empty():
		return ToolResult.fail("Error: scope is required. Use 'workspace' for module-level or 'global' for project-level memories.")
	
	if not MemoryEntry.is_valid_scope(scope):
		return ToolResult.fail("Error: Invalid scope '%s'. Valid options: %s" % [scope, MemoryEntry.get_valid_scopes()])
	
	if title.is_empty() or content.is_empty() or memory_type.is_empty():
		return ToolResult.fail("Error: Title, Content, and Memory Type are required!")
	
	if not MemoryEntry.is_valid_type(memory_type):
		return ToolResult.fail("Error: Invalid memory type '%s'. Valid options: %s" % [memory_type, MemoryEntry.get_valid_types()])
	
	if topic.is_empty():
		return ToolResult.fail("Error: topic is required. Use get_memory_topics to see existing topics or create a new one.")
	
	var store := MemoryStore.load_or_create()
	var entry := store.add_entry(title, content, memory_type, scope, workspace_path, "", topic)
	
	if not entry:
		return ToolResult.fail("Error: Failed to add memory entry.")
	
	var err := store.save()
	if err != OK:
		return ToolResult.fail("Error: Failed to save memory store: %s" % error_string(err))
	
	var result: String = "Memory stored successfully.\n"
	result += "Scope: %s\n" % entry.scope
	result += "Workspace: %s\n" % entry.workspace_path
	result += "Topic: %s\n" % entry.topic
	result += "Title: %s\n" % entry.title
	result += "Type: %s\n" % entry.memory_type
	result += "Content: %s" % entry.content
	
	return ToolResult.ok(result)
