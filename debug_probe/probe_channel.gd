@tool
extends EditorDebuggerPlugin

# Editor-side channel between the AI Debug Probe module and the editor.
#
# This file belongs to godot_ai_chat (an EditorDebuggerPlugin can only exist while some
# EditorPlugin registers it with add_debugger_plugin): godot_ai_chat registers it on _enter_tree.
# The probe module itself — res://debug_probe — has no editor dependency at all.
#
# It carries no test logic of its own. It also caches each session's hello, which is how the tool
# learns what the running build actually supports instead of assuming.


# --- Constants ---

const CAPTURE: String = "ai_debug_probe"


# --- Public Vars ---

# Injected by whoever registers this plugin; read by the two probe tools.
static var instance: EditorDebuggerPlugin = null


# --- Private Vars ---

var _sessions: Dictionary = {}  # session_id -> hello payload
var _hello_at: Dictionary = {}  # session_id -> msec when that hello arrived
var _replies: Dictionary = {}   # request id -> reply body
var _abandoned: Dictionary = {}  # request id -> true: the caller already gave up waiting
var _next_id: int = 1


# --- Built-in Functions ---

func _has_capture(p_capture: String) -> bool:
	return p_capture == CAPTURE


func _capture(p_message: String, p_data: Array, p_session_id: int) -> bool:
	# Unlike the game-side capture, this one receives the full prefix ("ai_debug_probe:hello").
	var name: String = p_message.trim_prefix(CAPTURE + ":")
	match name:
		"hello":
			var hello: Variant = _parse(p_data)
			_sessions[p_session_id] = hello if typeof(hello) == TYPE_DICTIONARY else {}
			_hello_at[p_session_id] = Time.get_ticks_msec()
		"idle":
			if not _sessions.has(p_session_id):
				_sessions[p_session_id] = {}
		"reply":
			var body: Variant = _parse(p_data)
			if typeof(body) == TYPE_DICTIONARY:
				var id: int = int(body.get("id", 0))
				# A reply whose caller already timed out has nobody to go to: keeping it would hold a
				# whole sample blob alive for the rest of the session.
				if _abandoned.has(id):
					_abandoned.erase(id)
				else:
					_replies[id] = body
	
	return true


# --- Public Functions ---

# Every session that currently has a probe node, oldest first.
func live_sessions() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	
	for raw_id: Variant in _sessions.keys():
		var sid: int = int(raw_id)
		var session: EditorDebuggerSession = get_session(sid)
		if session == null or not session.is_active():
			_sessions.erase(raw_id)
			_hello_at.erase(raw_id)
			# Request ids are global, not per session: with every session gone, nothing is left that
			# could ever answer an abandoned one.
			if _sessions.is_empty():
				_abandoned.clear()
			continue
		# The whole hello goes through: the channel must not decide which capabilities a probe
		# build is allowed to advertise, or every new field would need an edit here too.
		var hello: Dictionary = _sessions[raw_id]
		var entry: Dictionary = hello.duplicate(true)
		entry["session_id"] = sid
		out.append(entry)
	
	return out


# The most recently attached session, or -1 when no game has a probe.
func latest_session_id() -> int:
	var live: Array[Dictionary] = live_sessions()
	if live.is_empty():
		return -1
	
	return int(live[live.size() - 1].session_id)


# Waits for a handshake that arrived after p_since_msec. play_custom_scene returns before the game
# has even started, and the editor REUSES the session id when it restarts a run — so neither "any
# live session" nor "a session id not seen before" identifies the run we just started. A timestamp
# does, and it also ignores a still-running previous game.
func await_hello(p_since_msec: int, p_timeout: float) -> Dictionary:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null:
		return {}
	var deadline: int = Time.get_ticks_msec() + int(p_timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		for entry: Dictionary in live_sessions():
			var session_id: int = int(entry.session_id)
			# "probe": true is what hello() always sends; the "idle" marker is not a handshake.
			if int(_hello_at.get(session_id, 0)) >= p_since_msec and bool(entry.get("probe", false)):
				return entry
		await tree.process_frame
	return {}


# Sends one request and waits for its reply; returns {} on timeout.
func request(p_session_id: int, p_payload: Dictionary, p_timeout: float) -> Dictionary:
	var session: EditorDebuggerSession = get_session(p_session_id)
	if session == null or not session.is_active():
		return {}
	
	var id: int = _next_id
	_next_id += 1
	var payload: Dictionary = p_payload.duplicate(true)
	payload.id = id
	session.send_message(CAPTURE + ":request", [JSON.stringify(payload)])
	
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	var deadline: int = Time.get_ticks_msec() + int(p_timeout * 1000.0)
	
	while Time.get_ticks_msec() < deadline:
		if _replies.has(id):
			var body: Dictionary = _replies[id]
			_replies.erase(id)
			return body
		await tree.process_frame
	
	_replies.erase(id)
	# Nobody is waiting for this id any more: say so, so the late reply gets dropped on arrival
	# instead of being kept for the rest of the session.
	_abandoned[id] = true
	return {}


# --- Private Functions ---

func _parse(p_data: Array) -> Variant:
	if p_data.is_empty():
		return null
	
	return JSON.parse_string(str(p_data[0]))
