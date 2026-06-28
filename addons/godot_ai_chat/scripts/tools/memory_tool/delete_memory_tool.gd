@tool
extends AiTool


func _init() -> void:
	tool_name = "delete_memory"
	tool_description = "Delete a memory entry by its ID. Use `search_memories` to get memory ID"


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"id": {
				"type": "integer",
				"description": "The ID of the memory entry to delete."
			}
		},
		"required": ["id"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var mem_id: int = p_args.get("id", -1)
	
	if mem_id < 1:
		return ToolResult.fail("Error: A valid 'id' (positive integer) is required.")
	
	var store := _load_or_create_store()
	
	# 先查找记忆条目，用于反馈信息
	var target_entry: MemoryEntry = null
	for entry in store.entries:
		if entry.id == mem_id:
			target_entry = entry
			break
	
	if not target_entry:
		return ToolResult.fail("Error: No memory found with ID '%d'." % mem_id)
	
	var deleted_title: String = target_entry.title
	var deleted_topic: String = target_entry.topic
	var deleted_type: String = target_entry.memory_type
	var deleted_scope: String = target_entry.scope
	
	var success: bool = store.delete_entry(mem_id)
	if not success:
		return ToolResult.fail("Error: Failed to delete memory with ID '%d'." % mem_id)
	
	var err := store.save()
	if err != OK:
		return ToolResult.fail("Error: Failed to save memory store after deletion: %s" % error_string(err))
	
	var result: String = "Memory deleted successfully.\n"
	result += "ID: %d\n" % mem_id
	result += "Title: %s\n" % deleted_title
	result += "Topic: %s\n" % deleted_topic
	result += "Type: %s\n" % deleted_type
	result += "Scope: %s" % deleted_scope
	
	return ToolResult.ok(result)


func _load_or_create_store() -> MemoryStore:
	if ResourceLoader.exists(MemoryStore.SAVE_PATH):
		return load(MemoryStore.SAVE_PATH) as MemoryStore
	
	var store := MemoryStore.new()
	store.save()
	return store
