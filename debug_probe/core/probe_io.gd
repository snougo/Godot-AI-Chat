extends RefCounted

# Debugger transport: sends messages and builds the hello that advertises this build's
# capabilities. Nothing else in the game-side code needs to know the capture name.

# --- Public Vars ---

var capture: String = ""

# --- Built-in Functions ---

func _init(p_capture: String) -> void:
	capture = p_capture

# --- Public Functions ---

func send(p_message: String, p_body: Dictionary) -> void:
	EngineDebugger.send_message(capture + ":" + p_message, [JSON.stringify(p_body)])


func reply(p_payload: Dictionary, p_ok: bool, p_body: Variant) -> void:
	var out: Dictionary = {"id": p_payload.get("id", 0), "ok": p_ok}
	if p_ok:
		out.result = p_body
	else:
		out.error = str(p_body)
	send("reply", out)


# The capability advertisement, generated from the registries so it can never drift from the
# implementation. The editor-side tool validates requests against it.
func hello(p_context, p_version: String, p_max_frames: int) -> Dictionary:
	return {
		"probe": true,
		"version": p_version,
		"inputs": p_context.input_keys(),
		"observes": p_context.observe_keys(),
		"units": p_context.units(),
		"limits": {"max_frames": p_max_frames},
		"physics_frames": p_context.physics_frames,
		"idle_frames": p_context.idle_frames,
	}
