extends RefCounted

# Plan input "query": ask the physics server about geometry at the end of this frame.
#
#   {"at": 30, "query": [
#     {"as": "ground", "kind": "ray", "from": "/root/Game/Player", "offset": [0, -0.9, 0],
#      "direction": [0, -1, 0], "length": 0.6},
#     {"as": "front",  "kind": "ray", "from": "/root/Game/Player", "length": 5},
#     {"as": "around", "kind": "near", "from": "/root/Game/Player", "radius": 6}
#   ]}
#
# Evaluated by the step runner at the end of the frame the entry belongs to — the same moment a
# sample or a check sees, and before both, so "watch": ["queries"] and a "check" on
# "queries/front/distance" both read this frame's answer.
#
# Results are sticky per "as" label: the latest answer stays available on later frames, which is
# what makes it usable from "check" at any offset.
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Public Functions ---

func keys() -> Array[String]:
	return ["query"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	var entries: Array = []
	if typeof(p_payload) == TYPE_ARRAY:
		entries = p_payload
	elif typeof(p_payload) == TYPE_DICTIONARY:
		entries = [p_payload]
	else:
		push_warning("[AiDebugProbe] query: payload must be an object or an array of objects")
		return null
	if entries.is_empty():
		return null
	var scheduled: Array = p_context.queries.get(p_index, [])
	scheduled.append_array(entries)
	p_context.queries[p_index] = scheduled
	return null


func cleanup() -> void:
	pass
