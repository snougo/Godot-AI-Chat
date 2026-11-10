extends RefCounted

# Plan input "contact": add nodes whose contacts the "contacts" observer should also report.
#
#   {"at": 0, "contact": [{"path": "/root/Game/Wall"}, {"path": "/root/Game/Crate"}]}
#   {"at": 0, "contact": {"path": "/root/Game/Wall"}}
#   {"at": 0, "contact": {"clear": true}}
#
# Subscriptions accumulate and survive across steps, like every other setup action: they are
# experiment configuration, not per-frame state. The player is always reported at the top level of
# the sample, so subscribing to it is only needed when its report should appear under "targets"
# alongside the others.
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Public Functions ---

func keys() -> Array[String]:
	return ["contact"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	var entries: Array = []
	if typeof(p_payload) == TYPE_ARRAY:
		entries = p_payload
	elif typeof(p_payload) == TYPE_DICTIONARY:
		entries = [p_payload]
	else:
		return {"kind": "contact", "at": p_index,
			"error": "payload must be an object or an array of objects"}

	var added: Array[String] = []
	for raw: Variant in entries:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = raw
		if bool(entry.get("clear", false)):
			p_context.contact_targets.clear()
		var paths: Array = []
		if entry.has("path"):
			paths.append(str(entry.path))
		for one: Variant in entry.get("targets", []):
			paths.append(str(one))
		for path: String in paths:
			if p_context.contact_targets.has(path):
				continue
			p_context.contact_targets.append(path)
			added.append(path)

	var unresolved: Array[String] = []
	for path: String in added:
		if p_context.tree().root.get_node_or_null(path) == null:
			unresolved.append(path)
	return {"kind": "contact", "at": p_index, "added": added,
		"count": p_context.contact_targets.size(),
		"unresolved": unresolved, "error": ""}


func cleanup() -> void:
	pass
