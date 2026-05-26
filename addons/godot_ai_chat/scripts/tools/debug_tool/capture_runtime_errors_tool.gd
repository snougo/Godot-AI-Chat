@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "capture_runtime_errors"
	tool_description = "Captures runtime error messages from the game console for AI code debugging. Use 'start' to enable file logging and begin monitoring, 'get_errors' to retrieve all captured errors, 'stop' to disable file logging, and 'clear' to reset."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["start", "stop", "get_errors", "clear"],
				"description": "'start' - enables file logging and begins monitoring for runtime errors. 'stop' - disables file logging. 'get_errors' - returns all captured errors since last start. 'clear' - clears the captured error log and resets position."
			}
		},
		"required": ["action"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")

	if action.is_empty():
		return {"success": false, "data": "Error: 'action' is required. Use 'start', 'stop', 'get_errors', or 'clear'."}

	match action:
		"start":
			return _start()
		"stop":
			return _stop()
		"get_errors":
			return _get_errors()
		"clear":
			return _clear()
		_:
			return {"success": false, "data": "Error: Unknown action '%s'. Use 'start', 'stop', 'get_errors', or 'clear'." % action}


func _start() -> Dictionary:
	if ErrorCaptureBridge.is_capturing:
		return {"success": false, "data": "Already capturing. Use 'stop' first or 'clear' to reset."}

	# 1. 启用文件日志
	ErrorCaptureBridge.enable_file_logging()

	# 2. 清空旧记录
	ErrorCaptureBridge.captured_errors.clear()

	# 3. 记录当前日志位置（后续只读取增量部分）
	ErrorCaptureBridge.record_current_position()

	# 4. 标记开始
	ErrorCaptureBridge.is_capturing = true

	return {
		"success": true,
		"data": "🔴 Started capturing runtime errors.\n\n"
			  + "Now run your game scene. When errors appear, call 'get_errors' to retrieve them.\n"
			  + "Use 'stop' to disable file logging when done."
	}


func _stop() -> Dictionary:
	if not ErrorCaptureBridge.is_capturing:
		return {"success": false, "data": "Not currently capturing. Use 'start' to begin."}

	# 先读取一次剩余错误
	ErrorCaptureBridge.read_new_errors()

	# 禁用文件日志
	ErrorCaptureBridge.disable_file_logging()

	ErrorCaptureBridge.is_capturing = false
	var count: int = ErrorCaptureBridge.captured_errors.size()

	return {
		"success": true,
		"data": "⏹️ Stopped capturing. %d error(s) captured. Use 'get_errors' to view them." % count
	}


func _get_errors() -> Dictionary:
	# 读取自上次以来的新错误
	ErrorCaptureBridge.read_new_errors()

	if ErrorCaptureBridge.captured_errors.is_empty():
		return {"success": true, "data": "✅ No errors captured."}

	var report: String = ErrorCaptureBridge.get_formatted_report()
	return {"success": true, "data": report}


func _clear() -> Dictionary:
	ErrorCaptureBridge.captured_errors.clear()
	ErrorCaptureBridge.record_current_position()
	return {"success": true, "data": "🧹 Cleared all captured errors and reset log position."}
