extends RefCounted

# Plan input "replay": mark this step as a baseline, compare it against one, or drop one.
#
#   {"at": 0, "replay": {"id": "hp-drain", "mode": "record"}}
#   {"at": 0, "replay": {"id": "hp-drain", "mode": "compare"}}
#   {"at": 0, "replay": {"id": "hp-drain", "mode": "clear"}}
#
# The baseline lives in user:// rather than in memory on purpose: a regression harness is only
# worth anything if the baseline survives the editor restarting the game. The step's reply carries
# either "identical": true or a short list of differences (see core/diff.gd).
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Constants ---

const ReplayStore := preload("res://debug_probe/core/replay_store.gd")

const MODES: Array[String] = ["record", "compare", "clear"]

# --- Public Functions ---

func keys() -> Array[String]:
	return ["replay"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	if typeof(p_payload) != TYPE_DICTIONARY:
		return {"kind": "replay", "at": p_index, "error": "payload must be an object"}
	var id: String = str(p_payload.get("id", ""))
	if id.is_empty():
		return {"kind": "replay", "at": p_index, "error": "\"id\" is required"}
	var mode: String = str(p_payload.get("mode", "compare"))
	if not MODES.has(mode):
		return {"kind": "replay", "at": p_index,
			"error": "unknown mode '%s' (supported: %s)" % [mode, ", ".join(MODES)]}
	# One step, one record: a second entry would silently replace the first, which is exactly the
	# kind of quiet no-op the probe is supposed to avoid.
	if p_context.replay_request.has("id"):
		return {"kind": "replay", "at": p_index,
			"error": "this step already replays '%s'; one replay per step" % p_context.replay_request.id}
	# The runner reads this once the step is over; the row below only announces the intent.
	p_context.replay_request = {"id": id, "mode": mode}
	return {"kind": "replay", "at": p_index, "id": id, "mode": mode,
		"file": ReplayStore.path_of(id), "error": ""}


func cleanup() -> void:
	pass
