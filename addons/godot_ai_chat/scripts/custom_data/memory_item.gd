@tool
class_name MemoryItem
extends Resource

## 唯一ID（递增）
@export var id: int = 0
## 记忆标题
@export var title: String = ""
## 写入时间
@export var created_time: String = ""
## 记忆内容
@export_multiline var content: String = ""
## 记忆标签（用于记忆搜索）
@export var tags: Array[String] = []


## 初始化创建时间
func _init() -> void:
	if created_time.is_empty():
		created_time = Time.get_datetime_string_from_system()
