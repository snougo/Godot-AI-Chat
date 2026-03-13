@tool
class_name MemoryArchive
extends Resource

const SAVE_PATH: String = PluginPaths.PLUGIN_DIR + "memory_archive.tres"

@export var memories: Array[MemoryItem] = []


## 获取下一个可用 ID
func get_next_id() -> int:
	if memories.is_empty():
		return 1
	var max_id: int = 0
	for item in memories:
		if item.id > max_id:
			max_id = item.id
	return max_id + 1


## 添加记忆
func add_memory(p_title: String, p_content: String, p_tags: Array[String] = []) -> MemoryItem:
	var item := MemoryItem.new()
	item.id = get_next_id()
	item.title = p_title
	item.content = p_content
	item.tags = p_tags.duplicate()
	
	memories.append(item)
	return item


## 搜索记忆（按 Tag）
func search_memories(p_query: String, p_limit: int = 5) -> Array[MemoryItem]:
	if p_limit <= 0:
		p_limit = 5  # 或使用默认值
	
	var results: Array[MemoryItem] = []
	
	for item in memories:
		for tag in item.tags:
			if tag.to_lower().contains(p_query.to_lower()):
				results.append(item)
				break
	
	# Sort by time (newest first)
	results.sort_custom(func(a, b): return a.created_time > b.created_time)
	
	if results.size() > p_limit:
		results = results.slice(0, p_limit)
	
	return results


## 获取所有已存在的标签（去重）
func get_all_tags() -> Array[String]:
	var all_tags: Array[String] = []
	for item in memories:
		for tag in item.tags:
			if tag not in all_tags:
				all_tags.append(tag)
	return all_tags


## 保存到磁盘
func save() -> Error:
	return ResourceSaver.save(self, SAVE_PATH)
