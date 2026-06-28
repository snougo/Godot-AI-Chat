@tool
class_name MemoryEntry
extends Resource

## 记忆条目
## 存储一条结构化的记忆信息，用于 AI 的长期记忆系统。


## 作用域常量
const VALID_SCOPES: Array[String] = [
	"workspace",   # 工作区级——只与特定工作区相关
	"global"       # 全局级——适用于整个项目
]

## 记忆类型常量
const VALID_MEMORY_TYPES: Array[String] = [
	"session_summary",    # 会话摘要（仅限 workspace）
	"user_preference",    # 用户偏好
	"project_decision",   # 项目决策
	"lesson_learned",     # 经验教训
	"bug_fix"             # Bug 修复记录（仅限 workspace）
]

## 记忆ID
@export var id: int = 0
## 作用域 workspace | global
@export var scope: String = "workspace"
## 记忆类型
@export var memory_type: String = "session_summary"
## 记忆话题组
@export var topic: String = ""
## 记忆标题
@export var title: String = ""
## 记忆内容
@export_multiline var content: String = ""
## 作用域路径 所属工作区（global 级可留空或用 "res://"）
@export var workspace_path: String = ""
## 记忆会话源
@export var session_source: String = ""
## 记忆时间
@export var created_at: String = ""
## 最后的访问时间
@export var last_accessed: String = ""
## 被访问次数
@export var access_count: int = 0


func _init() -> void:
	if created_at.is_empty():
		created_at = Time.get_datetime_string_from_system()
	if last_accessed.is_empty():
		last_accessed = created_at


## 验证作用域
static func is_valid_scope(p_scope: String) -> bool:
	return p_scope in VALID_SCOPES


## 验证记忆类型
static func is_valid_type(p_type: String) -> bool:
	return p_type in VALID_MEMORY_TYPES


## 获取作用域
static func get_valid_scopes() -> Array[String]:
	return VALID_SCOPES.duplicate()


## 获取记忆类型
static func get_valid_types() -> Array[String]:
	return VALID_MEMORY_TYPES.duplicate()
