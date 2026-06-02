@tool
extends EditorDebuggerPlugin

## 运行时错误调试器（编辑器端）
##
## 接收游戏端通过 EngineDebugger.send_message() 发来的 "my_plugin:" 消息，
## 缓存在静态变量中供 CaptureRuntimeErrorsTool 读取。

# --- Static Storage ---

static var captured_errors: Array[Dictionary] = []


# --- Built-in Functions ---

func _has_capture(prefix: String) -> bool:
	return prefix == "my_plugin"


func _capture(message: String, data: Array, _session_id: int) -> bool:
	if message == "my_plugin:runtime_error":
		var err_info: Dictionary = data[0] if data.size() > 0 else {}
		captured_errors.append(err_info)
		return true
	
	return false
