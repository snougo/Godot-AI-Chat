@tool
class_name MemoryStore
extends Resource

## 记忆仓库
## 管理所有记忆条目的存储、检索、召回。

const SAVE_PATH: String = PluginPaths.PLUGIN_DIR + "memory_store.tres"

## 类型排序权重（数值越小越靠前）
const TYPE_ORDER: Dictionary = {
	"session_summary": 0,
	"lesson_learned": 1,
	"user_preference": 2,
	"project_decision": 3,
	"bug_fix": 4
}

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
		p_importance: int = 3, p_scope: String = "workspace",
		p_workspace_path: String = "", p_session_source: String = "") -> MemoryEntry:
	if not MemoryEntry.is_valid_type(p_type):
		push_error("Invalid memory type: %s" % p_type)
		return null
	if not MemoryEntry.is_valid_scope(p_scope):
		push_error("Invalid scope: %s" % p_scope)
		return null
	
	var entry := MemoryEntry.new()
	entry.id = get_next_id()
	entry.title = p_title
	entry.content = p_content
	entry.scope = p_scope
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
## [param p_sort_by]: 排序方式 — default | created_at | last_accessed | importance | access_count
## [param p_memory_type]: 按类型过滤（空字符串表示不过滤）
## [param p_min_importance]: 最小重要性 (1-5)
## [param p_max_importance]: 最大重要性 (1-5)
func search(p_workspace_path: String = "", 
			p_keywords: String = "", 
			p_limit: int = 10, 
			p_sort_by: String = "default", 
			p_memory_type: String = "", 
			p_min_importance: int = 1, 
			p_max_importance: int = 5) -> Array[MemoryEntry]:
	
	var results: Array[MemoryEntry] = []
	
	for entry in entries:
		# 工作区过滤：如果传了工作区路径
		if not p_workspace_path.is_empty():
			if _normalize_path(entry.workspace_path) != _normalize_path(p_workspace_path):
				continue
		
		# 模糊关键词搜索
		if not p_keywords.is_empty():
			var text_lower: String = (entry.title + " " + entry.content).to_lower()
			if not _fuzzy_match(p_keywords.to_lower(), text_lower):
				continue
		
		# 类型过滤
		if not p_memory_type.is_empty() and entry.memory_type != p_memory_type:
			continue
		
		# 重要性范围过滤
		if entry.importance < p_min_importance or entry.importance > p_max_importance:
			continue
		
		results.append(entry)
	
	# 根据 sort_by 参数选择排序方式
	match p_sort_by:
		"created_at":
			results.sort_custom(func(a: MemoryEntry, b: MemoryEntry) -> bool:
				return a.created_at > b.created_at)
		"last_accessed":
			results.sort_custom(func(a: MemoryEntry, b: MemoryEntry) -> bool:
				return a.last_accessed > b.last_accessed)
		"importance":
			results.sort_custom(func(a: MemoryEntry, b: MemoryEntry) -> bool:
				return a.importance > b.importance)
		"access_count":
			results.sort_custom(func(a: MemoryEntry, b: MemoryEntry) -> bool:
				return a.access_count > b.access_count)
		_:  # "default"
			results.sort_custom(_compare_entries)
	
	if results.size() > p_limit:
		results = results.slice(0, p_limit)
	
	for entry in results:
		entry.access_count += 1
		entry.last_accessed = Time.get_datetime_string_from_system()
	
	return results


## 根据工作区召回相关记忆（用于 ContextBuilder 自动注入）
func get_relevant(p_workspace_path: String, p_limit: int = 5) -> Array[MemoryEntry]:
	if p_workspace_path.is_empty():
		return []
	
	var global_results: Array[MemoryEntry] = []
	var workspace_results: Array[MemoryEntry] = []
	
	for entry in entries:
		if entry.scope == "global":
			global_results.append(entry) # 全局：全部收集
		elif _normalize_path(entry.workspace_path) == _normalize_path(p_workspace_path):
			workspace_results.append(entry) # 工作区：需路径匹配
	
	# 工作区记忆：排序 + 截断（受 limit 限制）
	workspace_results.sort_custom(_compare_entries)
	if workspace_results.size() > p_limit:
		workspace_results = workspace_results.slice(0, p_limit)
	
	# 全局记忆：排序但不截断
	global_results.sort_custom(_compare_entries)
	
	# 合并：全局在前，工作区在后
	var results: Array[MemoryEntry] = global_results + workspace_results
	
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
	# 1 按类型排序
	var a_order: int = TYPE_ORDER.get(a.memory_type, 99)
	var b_order: int = TYPE_ORDER.get(b.memory_type, 99)
	if a_order != b_order:
		return a_order < b_order
	
	# 2 按重要性降序
	if a.importance != b.importance:
		return a.importance > b.importance
	
	# 3 按时间降序
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
