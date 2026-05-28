@tool
class_name MemoryStore
extends Resource

## 记忆仓库
## 管理所有记忆条目的存储、检索、召回。

const SAVE_PATH: String = PluginPaths.PLUGIN_DIR + "memory_store.tres"

@export var entries: Array[MemoryEntry] = []


# --- 基础操作 ---

func get_next_id() -> int:
	if entries.is_empty():
		return 1
	var max_id: int = 0
	for item in entries:
		if item.id > max_id:
			max_id = item.id
	return max_id + 1


## 添加记忆条目
func add_entry(p_title: String, p_content: String, p_type: String,
		p_importance: int = 3, p_workspace_path: String = "",
		p_session_source: String = "") -> MemoryEntry:
	if not MemoryEntry.is_valid_type(p_type):
		push_error("Invalid memory type: %s" % p_type)
		return null
	
	var entry := MemoryEntry.new()
	entry.id = get_next_id()
	entry.title = p_title
	entry.content = p_content
	entry.memory_type = p_type
	entry.importance = MemoryEntry.clamp_importance(p_importance)
	entry.workspace_path = p_workspace_path
	entry.session_source = p_session_source
	
	entries.append(entry)
	return entry


## 更新记忆条目
func update_entry(p_id: int, p_updates: Dictionary) -> bool:
	for entry in entries:
		if entry.id == p_id:
			if p_updates.has("title"): entry.title = p_updates.title
			if p_updates.has("content"): entry.content = p_updates.content
			if p_updates.has("memory_type") and MemoryEntry.is_valid_type(p_updates.memory_type):
				entry.memory_type = p_updates.memory_type
			if p_updates.has("importance"):
				entry.importance = MemoryEntry.clamp_importance(p_updates.importance)
			if p_updates.has("workspace_path"): entry.workspace_path = p_updates.workspace_path
			return true
	return false


## 删除记忆条目
func delete_entry(p_id: int) -> bool:
	for i in range(entries.size()):
		if entries[i].id == p_id:
			entries.remove_at(i)
			return true
	return false


# --- 检索 ---

## 多条件搜索（所有参数可选）
## 关键词使用词级模糊匹配（任意词命中即匹配）
func search(p_workspace_path: String = "", p_keywords: String = "",
		p_limit: int = 10) -> Array[MemoryEntry]:
	var results: Array[MemoryEntry] = []
	
	for entry in entries:
		# 工作区过滤
		if not p_workspace_path.is_empty() and entry.workspace_path != _normalize_path(p_workspace_path):
			continue
		
		# 模糊关键词搜索
		if not p_keywords.is_empty():
			var text_lower: String = (entry.title + " " + entry.content).to_lower()
			if not _fuzzy_match(p_keywords.to_lower(), text_lower):
				continue
		
		results.append(entry)
	
	results.sort_custom(_compare_entries)
	
	if results.size() > p_limit:
		results = results.slice(0, p_limit)
	
	# 更新访问信息
	for entry in results:
		entry.access_count += 1
		entry.last_accessed = Time.get_datetime_string_from_system()
	
	return results


## 根据工作区召回相关记忆（用于 ContextBuilder 自动注入）
func get_relevant(p_workspace_path: String, p_limit: int = 5) -> Array[MemoryEntry]:
	if p_workspace_path.is_empty():
		return []
	
	var results: Array[MemoryEntry] = []
	for entry in entries:
		if entry.workspace_path == _normalize_path(p_workspace_path):
			results.append(entry)
	
	results.sort_custom(_compare_entries)
	
	if results.size() > p_limit:
		results = results.slice(0, p_limit)
	
	# 更新访问信息
	for entry in results:
		entry.access_count += 1
		entry.last_accessed = Time.get_datetime_string_from_system()
	
	return results


## 获取统计信息
func get_statistics() -> Dictionary:
	var stats: Dictionary = {}
	for mtype in MemoryEntry.get_valid_types():
		stats[mtype] = {"count": 0, "total_importance": 0}
	
	for entry in entries:
		if stats.has(entry.memory_type):
			stats[entry.memory_type].count += 1
			stats[entry.memory_type].total_importance += entry.importance
	
	for mtype in stats:
		if stats[mtype].count > 0:
			stats[mtype].avg_importance = float(stats[mtype].total_importance) / stats[mtype].count
		else:
			stats[mtype].avg_importance = 0.0
		stats[mtype].erase("total_importance")
	
	return stats


# --- 持久化 ---

func save() -> Error:
	return ResourceSaver.save(self, SAVE_PATH)


# --- 内部方法 ---

# 路径归一化：去除尾部斜杠，确保路径比较一致性
static func _normalize_path(p_path: String) -> String:
	return p_path.trim_suffix("/").trim_suffix("\\")


func _compare_entries(a: MemoryEntry, b: MemoryEntry) -> bool:
	if a.importance != b.importance:
		return a.importance > b.importance
	return a.created_at > b.created_at


# 词级模糊匹配：查询词中的任意一个词出现在文本中即匹配
func _fuzzy_match(p_query: String, p_text: String) -> bool:
	# 按空格分词（适用于英文）
	var words: PackedStringArray = p_query.split(" ", false)
	for word in words:
		word = word.strip_edges()
		if word.length() >= 2 and p_text.contains(word):
			return true
	
	# 提取中文双字词进行匹配
	var bigrams: Array[String] = _extract_chinese_bigrams(p_query)
	for bigram in bigrams:
		if p_text.contains(bigram):
			return true
	
	return false


# 提取中文双字词
func _extract_chinese_bigrams(p_text: String) -> Array[String]:
	var result: Array[String] = []
	var chars: Array[String] = []
	for c in p_text:
		var code: int = c.unicode_at(0)
		if code >= 0x4E00 and code <= 0x9FFF:
			chars.append(c)
	
	for i in range(chars.size() - 1):
		var bigram: String = chars[i] + chars[i + 1]
		if not bigram in result:
			result.append(bigram)
	
	return result
