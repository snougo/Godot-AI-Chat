@tool
class_name MemoryItem extends Resource

@export var id: int = 0
@export var title: String = ""
@export var created_time: String = ""
@export_multiline var content: String = ""
@export var tags: Array[String] = []


## 初始化创建时间
func _init() -> void:
	if created_time.is_empty():
		created_time = Time.get_datetime_string_from_system()
