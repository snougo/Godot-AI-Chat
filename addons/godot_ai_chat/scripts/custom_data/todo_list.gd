@tool
class_name AiTodoList
extends Resource

## 所有任务列表
@export var items: Array[AiTodoItem] = []


## 添加任务
func add_item(p_content: String, p_workspace_path: String) -> void:
	var item = AiTodoItem.new(p_content, p_workspace_path)
	items.append(item)
	emit_changed()


## 获取指定上下文的任务列表
## 如果 p_workspace_path 为空，返回所有任务
## 否则仅返回 p_workspace_path 严格匹配的任务
func get_items(p_workspace_path: String = "") -> Array[AiTodoItem]:
	if p_workspace_path.is_empty():
		return items
	
	var filtered: Array[AiTodoItem] = []
	for item in items:
		# 严格匹配当前工作区，实现“每个工作区独立”的效果
		if item.workspace_path == p_workspace_path:
			filtered.append(item)
	return filtered


## 标记任务为完成
## 返回是否成功找到并标记
func mark_as_completed(p_content_match: String) -> bool:
	for item in items:
		if not item.is_completed and p_content_match in item.content:
			item.is_completed = true
			emit_changed()
			return true
	return false
