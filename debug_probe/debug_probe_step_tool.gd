extends AiTool

# Drives the AI Debug Probe module frame by frame.
#
# DEPENDS ON: the AI Debug Probe module at res://debug_probe/ (game side) and the channel next
# to this file (editor side). Both must be present: the module provides the node that answers,
# the channel carries the messages. godot_ai_chat itself only hosts them.
#
# One call = one frame step plus samples. Validates every request against the capability list the
# game advertised in its hello, so a version mismatch fails loudly instead of quietly returning
# empty samples.


# --- Constants ---

const ChannelScript := preload("res://debug_probe/probe_channel.gd")


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "debug_probe_step"
	tool_description = "Advance the game running under the AI Debug Probe exactly N frames and return samples."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"frames": {
				"type": "integer",
				"description": "Frames to advance (1 to the limit the probe reports, usually 600).",
				"default": 1
			},
			"unit": {
				"type": "string",
				"enum": ["physics", "idle"],
				"description": "What one frame is: \"physics\" ticks (deterministic, default) or \"idle\" render frames (delta varies with real time, so positions may not be reproducible).",
				"default": "physics"
			},
			"plan": {
				"type": "array",
				"description": "Frame-offset actions: [{\"at\":0,\"press\":[\"ui_right\"]},{\"at\":5,\"release\":[\"ui_right\"]},{\"at\":9,\"click\":[\"HUD.StartButton\"]}]. press/release names resolve to an InputMap action first, otherwise a Godot key name. click takes the UI keys reported by watch ui.",
				"items": {"type": "object"}
			},
			"samples": {
				"type": "array",
				"description": "Frame offsets to sample, relative to this step. Empty: only the last frame.",
				"items": {"type": "integer"}
			},
			"watch": {
				"type": "array",
				"description": "What to collect per sample. Supported keys are reported by the running probe.",
				"items": {"type": "string"}
			},
			"timeout": {
				"type": "number",
				"description": "Seconds to wait for the reply. Omitted: estimated from frames and unit (twice the expected duration plus two seconds), so a long step is not misreported as a wedged probe."
			}
		},
		"required": ["frames"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var channel: Variant = ChannelScript.instance
	if channel == null:
		return ToolResult.fail("Error: the AI Debug Probe channel is not registered. Is the AI Debug Probe module present at res://debug_probe and godot_ai_chat enabled?")
	var session_id: int = channel.latest_session_id()
	if session_id < 0:
		return ToolResult.fail("Error: no running game has an AiDebugProbe node. Launch one with ai_debug_launch.")
	
	var hello: Dictionary = {}
	for entry: Dictionary in channel.live_sessions():
		if int(entry.session_id) == session_id:
			hello = entry
			break
	# "probe": true is what a real handshake carries (see probe_io.hello). The channel also records a
	# bare session on an "idle" message, and that one knows nothing about the build: without this
	# check every capability would be reported as unsupported, blaming the probe version.
	if not bool(hello.get("probe", false)):
		return ToolResult.fail("Error: the game's probe has not finished starting (no capability handshake yet). Give it a moment and call again.")
	
	var frames: int = int(p_args.get("frames", 1))
	var unit: String = str(p_args.get("unit", "physics"))
	var payload: Dictionary = {
		"frames": frames,
		"unit": unit,
		"plan": p_args.get("plan", []),
		"samples": p_args.get("samples", []),
		"watch": p_args.get("watch", ["pose", "errors"]),
	}
	
	var unsupported: Array[String] = _unsupported(payload, hello)
	if not unsupported.is_empty():
		return ToolResult.fail("Error: this game's probe build does not support: %s. It supports plan keys %s and watch keys %s (probe version %s)." % [
			", ".join(unsupported),
			str(hello.get("inputs", [])),
			str(hello.get("observes", [])),
			str(hello.get("version", "unknown")),
		])
	
	var timeout: float = float(p_args.get("timeout", _estimated_timeout(frames, unit)))
	var reply: Dictionary = await channel.request(session_id, payload, timeout)
	if reply.is_empty():
		return ToolResult.fail(_no_reply_message(channel, session_id, timeout))
	if not bool(reply.get("ok", false)):
		var reason: String = str(reply.get("error", "unknown"))
		# "already running" / "stopped advancing" are how a wedged probe answers: the step that never
		# came back still occupies the runner, so every later request bounces off it.
		if reason.contains("already running") or reason.contains("stopped advancing"):
			return ToolResult.fail("Error: %s\n\n%s" % [reason, _stuck_hint()])
		return ToolResult.fail("Error: %s" % reason)
	
	return ToolResult.ok(JSON.stringify(reply.get("result", {}), "  "))


# --- Private Functions ---

# Request keys this build would silently ignore.
func _unsupported(p_payload: Dictionary, p_hello: Dictionary) -> Array[String]:
	var inputs: Array = p_hello.get("inputs", [])
	var observes: Array = p_hello.get("observes", [])
	var units: Array = p_hello.get("units", [])
	var out: Array[String] = []
	var unit: String = str(p_payload.get("unit", "physics"))
	
	if units.is_empty():
		# A build from before units were advertised: it only ever steps physics frames.
		if unit != "physics" and not out.has("unit '%s'" % unit):
			out.append("unit '%s' (this game's probe build does not advertise units, so it only steps physics)" % unit)
	elif not units.has(unit) and not out.has("unit '%s'" % unit):
		out.append("unit '%s'" % unit)
	
	for entry: Variant in p_payload.plan:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		for key: Variant in entry.keys():
			var name: String = str(key)
			if name != "at" and not inputs.has(name) and not out.has(name):
				out.append(name)
	
	for raw: Variant in p_payload.watch:
		var name: String = str(raw)
		if not observes.has(name) and not out.has(name):
			out.append(name)
	
	return out


# How long a request should wait for its reply. Stepping is real time, not fast-forward: the game
# advances frames as the engine produces them, so 600 physics ticks at 60 TPS take ten seconds. A
# fixed default made every long step time out and then reported it as a wedged probe. Twice the
# expected duration plus two seconds of slack; an explicit "timeout" always wins over this.
func _estimated_timeout(p_frames: int, p_unit: String) -> float:
	var rate: float = 60.0
	if p_unit == "physics":
		rate = float(Engine.physics_ticks_per_second)
	if p_frames <= 0 or rate <= 0.0:
		return 5.0
	return maxf(5.0, float(p_frames) / rate * 2.0 + 2.0)


# No reply means the game never finished a frame: the probe answers at the end of a step, so silence
# is "the main thread is not running frames", not "the request was rejected". Name the cause instead
# of leaving the reader to guess.
func _no_reply_message(p_channel: Variant, p_session_id: int, p_timeout: float) -> String:
	for entry: Dictionary in p_channel.live_sessions():
		if int(entry.get("session_id", -1)) == p_session_id:
			return ("Error: no reply from the game within %s s. A long step may simply still be running: " +
				"call again with a larger \"timeout\".\n\n%s") % [str(p_timeout), _stuck_hint()]
	
	return "Error: no reply: the probe session is gone (the game was stopped or its debugger disconnected). Launch it again with ai_debug_launch."


# The failure mode that looks like "the probe is broken" but starts on the game side: a GDScript
# runtime error calls into the debugger (debug_break), and while the editor's "Ignore Error Breaks"
# (the bell in the Debugger panel) is off, the game's main thread stays blocked there — so no frame
# ever completes and the probe looks dead.
func _stuck_hint() -> String:
	return ("Likely cause: the game is paused on a script error. A GDScript runtime error hands control " +
		"to the debugger (debug_break); with \"Ignore Error Breaks\" off, the game's main thread stays " +
		"blocked in that break, so the probe cannot finish a frame and later requests answer " +
		"\"a step is already running\".\n" +
		"Next: check read_errors for a fresh script error from this run. Fix it, or turn Ignore Error " +
		"Breaks on, then restart the game with ai_debug_launch — a wedged session usually does not recover.")
