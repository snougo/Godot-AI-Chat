@tool
class_name EditorScriptAutoBackup
extends Resource

## 持久化的编辑器脚本备份数据
## 存储执行前的文件内容和执行后的审计差异，用于手动回滚。

## 备份唯一标识（如 rollback_20260730_225500）
@export var backup_id: String = ""

## 创建时间戳（Unix 时间）
@export var timestamp: int = 0

## 执行的原脚本代码
@export var script_code: String = ""

## 备份的文件路径列表（与 file_contents 一一对应）
@export var file_paths: Array[String] = []

## 备份的文件内容列表（与 file_paths 一一对应）
@export var file_contents: Array[PackedByteArray] = []

## 审计：执行后创建的文件
@export var audit_created: Array[String] = []

## 审计：执行后修改的文件
@export var audit_modified: Array[String] = []

## 审计：执行后删除的文件
@export var audit_deleted: Array[String] = []


# --- Public Methods ---

## 添加一个备份文件
func add_file(p_path: String, p_content: PackedByteArray) -> void:
	file_paths.append(p_path)
	file_contents.append(p_content)


## 获取所有备份文件的映射 {path: PackedByteArray}
func get_files_map() -> Dictionary:
	var map: Dictionary = {}
	for i in file_paths.size():
		map[file_paths[i]] = file_contents[i]
	return map


## 确保备份目录存在，如果不存在则创建
static func ensure_backup_dir_exists() -> void:
	if not DirAccess.dir_exists_absolute(PluginPaths.BACKUP_DIR):
		var dir: DirAccess = DirAccess.open("res://")
		if dir:
			dir.make_dir_recursive("rollback_files")
