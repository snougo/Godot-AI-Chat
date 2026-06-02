extends Node

## 运行时错误捕获器（游戏端 Autoload）
##
## 通过 OS.add_logger() 注册自定义 Logger，截获 push_error 等错误，
## 并通过 EngineDebugger.send_message() 发送给编辑器。

# --- Custom Logger Class ---

class GameLogger extends Logger:
	func _log_error(
		p_function: String,
		p_file: String,
		p_line: int,
		p_code: String,
		p_rationale: String,
		p_editor_notify: bool,
		p_error_type: int,
		p_script_backtraces: Array
	) -> void:
		# 错误信息在 code 中（push_error 的文本内容）
		var err_data: Dictionary = {
			"function": p_function,
			"file": p_file,
			"line": p_line,
			"code": p_code,
			"rationale": p_rationale,
			"error_type": p_error_type,
			"backtraces": _format_backtraces(p_script_backtraces)
		}
		
		if EngineDebugger.is_active():
			EngineDebugger.send_message("my_plugin:runtime_error", [err_data])
	
	static func _format_backtraces(p_backtraces: Array) -> String:
		var result: String = ""
		for trace in p_backtraces:
			result += str(trace) + "\n"
		return result.strip_edges()


# --- Static Variables ---

static var _logger: GameLogger = null


# --- Static Init ---

static func _static_init() -> void:
	if not Engine.is_editor_hint():
		_logger = GameLogger.new()
		OS.add_logger(_logger)
