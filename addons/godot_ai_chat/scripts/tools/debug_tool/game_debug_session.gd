@tool
extends EditorDebuggerPlugin

## 持有活动的游戏调试会话，供 frame_step_game 工具使用。
## 注意：不使用 class_name，外部通过 preload 访问静态方法，
## 避免依赖全局类注册时机导致的编译错误。

static var _instance: EditorDebuggerPlugin = null

var _active_session: EditorDebuggerSession = null


static func register(p_editor_plugin: EditorPlugin) -> void:
	if _instance == null:
		var script: GDScript = load("res://addons/godot_ai_chat/scripts/tools/debug_tool/game_debug_session.gd")
		_instance = script.new()
		p_editor_plugin.add_debugger_plugin(_instance)


static func unregister(p_editor_plugin: EditorPlugin) -> void:
	if _instance != null:
		p_editor_plugin.remove_debugger_plugin(_instance)
		_instance = null


static func get_instance() -> EditorDebuggerPlugin:
	return _instance


## 返回当前活动会话；无则返回 null
func get_active_session() -> EditorDebuggerSession:
	if _active_session and _active_session.is_active():
		return _active_session
	_active_session = null
	for s in get_sessions():
		if s.is_active():
			_active_session = s
			break
	return _active_session


func _setup_session(p_session_id: int) -> void:
	var session: EditorDebuggerSession = get_session(p_session_id)
	if session == null:
		return
	session.connect("started", _on_session_started.bind(session))
	session.connect("stopped", _on_session_stopped.bind(session))


func _on_session_started(p_session: EditorDebuggerSession) -> void:
	_active_session = p_session


func _on_session_stopped(p_session: EditorDebuggerSession) -> void:
	if _active_session == p_session:
		_active_session = null
