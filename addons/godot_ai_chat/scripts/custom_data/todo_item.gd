@tool
class_name TodoItem
extends Resource

## 任务内容
@export var content: String = ""
## 是否已完成
@export var is_completed: bool = false
## 关联的工作区路径（用于筛选）
@export var workspace_path: String = ""
## 创建时间
@export var creation_time: String = ""

func _init(p_content: String = "", p_context_path: String = "") -> void:
	content = p_content
	workspace_path = p_context_path
	creation_time = Time.get_datetime_string_from_system()
