@tool
class_name MemoryEntry
extends Resource

## 记忆条目
## 存储一条结构化的记忆信息，用于 AI 的长期记忆系统。

# --- 作用域常量 ---
const VALID_SCOPES: Array[String] = [
	"workspace",   # 工作区级——只与特定工作区相关
	"global"       # 全局级——适用于整个项目
]

# --- 记忆类型常量 ---
const VALID_MEMORY_TYPES: Array[String] = [
	"session_summary",    # 会话摘要（仅限 workspace）
	"user_preference",    # 用户偏好
	"project_decision",   # 项目决策
	"lesson_learned",     # 经验教训
	"bug_fix"             # Bug 修复记录（仅限 workspace）
]

const MIN_IMPORTANCE: int = 1
const MAX_IMPORTANCE: int = 5

# --- 导出字段 ---
@export var id: int = 0
@export var scope: String = "workspace"        # workspace | global
@export var memory_type: String = "session_summary"
@export var title: String = ""
@export_multiline var content: String = ""
@export var importance: int = 3
@export var workspace_path: String = ""        # 所属工作区（global 级可留空或用 "res://"）
@export var session_source: String = ""        # 来源会话文件名
@export var created_at: String = ""
@export var last_accessed: String = ""
@export var access_count: int = 0


func _init() -> void:
	if created_at.is_empty():
		created_at = Time.get_datetime_string_from_system()
	if last_accessed.is_empty():
		last_accessed = created_at


static func is_valid_scope(p_scope: String) -> bool:
	return p_scope in VALID_SCOPES


static func is_valid_type(p_type: String) -> bool:
	return p_type in VALID_MEMORY_TYPES


static func get_valid_scopes() -> Array[String]:
	return VALID_SCOPES.duplicate()


static func get_valid_types() -> Array[String]:
	return VALID_MEMORY_TYPES.duplicate()


static func clamp_importance(p_value: int) -> int:
	return clampi(p_value, MIN_IMPORTANCE, MAX_IMPORTANCE)
