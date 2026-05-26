@tool
class_name ErrorCaptureBridge
extends RefCounted

## 运行时错误捕获桥接器
##
## 通过读取 Godot 文件日志来捕获运行时的 GDScript 错误。
## 使用静态变量跨工具共享数据。

# --- 静态共享存储 ---
static var captured_errors: Array[String] = []
static var is_capturing: bool = false
static var log_position: int = 0

# --- 常量 ---
const LOG_PATH: String = "user://logs/godot.log"
const SETTING_ENABLE_LOG: String = "logging/file_logging/enable_file_logging"


## 启用文件日志
static func enable_file_logging() -> void:
	if not ProjectSettings.get_setting(SETTING_ENABLE_LOG, false):
		ProjectSettings.set_setting(SETTING_ENABLE_LOG, true)
		ProjectSettings.save()


## 禁用文件日志
static func disable_file_logging() -> void:
	if ProjectSettings.get_setting(SETTING_ENABLE_LOG, false):
		ProjectSettings.set_setting(SETTING_ENABLE_LOG, false)
		ProjectSettings.save()


## 记录当前日志文件位置（用于增量读取）
static func record_current_position() -> void:
	log_position = 0
	if FileAccess.file_exists(LOG_PATH):
		var file: FileAccess = FileAccess.open(LOG_PATH, FileAccess.READ)
		if file:
			log_position = file.get_length()
			file.close()


## 读取自上次位置以来的新错误
static func read_new_errors() -> void:
	if not FileAccess.file_exists(LOG_PATH):
		return

	var file: FileAccess = FileAccess.open(LOG_PATH, FileAccess.READ)
	if not file:
		return

	# 跳到上次读取位置
	file.seek(log_position)
	var new_content: String = file.get_as_text()
	log_position = file.get_length()
	file.close()

	if new_content.is_empty():
		return

	# 逐行解析错误
	var lines: PackedStringArray = new_content.split("\n")
	var current_error: String = ""
	var in_error: bool = false

	for line in lines:
		var trimmed: String = line.strip_edges()

		if trimmed.is_empty():
			if in_error and not current_error.is_empty():
				captured_errors.append(current_error.strip_edges())
				current_error = ""
				in_error = false
			continue

		# 检测错误行
		if trimmed.begins_with("ERROR:") or trimmed.begins_with("E 0:00:") or trimmed.begins_with("SCRIPT ERROR:"):
			if in_error and not current_error.is_empty():
				captured_errors.append(current_error.strip_edges())
			current_error = trimmed
			in_error = true
		elif in_error:
			current_error += "\n" + trimmed

	# 处理最后一个错误
	if in_error and not current_error.is_empty():
		captured_errors.append(current_error.strip_edges())


## 获取格式化后的错误报告
static func get_formatted_report() -> String:
	if captured_errors.is_empty():
		return "✅ No errors captured."

	var report: String = "📋 **Captured Runtime Errors** (%d total):\n\n" % captured_errors.size()
	for i in captured_errors.size():
		report += "--- Error #%d ---\n%s\n\n" % [i + 1, captured_errors[i]]

	return report
