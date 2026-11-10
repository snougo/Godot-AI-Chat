extends RefCounted

# Plan input "check": schedule assertions for the frame this entry is applied to.
#
#   {"at": 34, "check": [{"sample": "ui", "path": "texts/Settings.Summary",
#                         "op": "==", "value": "NAME=Arthur VOL=87 INV=on Q=High"}]}
#
# The entries are stored on the context and evaluated by the step runner at the end of that frame,
# which is the same moment — and the same offset — a sample would be taken at. Nothing is returned
# here: the pass/fail rows land in the step's "results" once the frame has run.
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Public Functions ---

func keys() -> Array[String]:
	return ["check"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	var entries: Array = []
	if typeof(p_payload) == TYPE_ARRAY:
		entries = p_payload
	elif typeof(p_payload) == TYPE_DICTIONARY:
		entries = [p_payload]
	else:
		push_warning("[AiDebugProbe] check: payload must be an object or an array of objects")
		return null
	if entries.is_empty():
		return null
	var scheduled: Array = p_context.checks.get(p_index, [])
	scheduled.append_array(entries)
	p_context.checks[p_index] = scheduled
	return null


func cleanup() -> void:
	pass
