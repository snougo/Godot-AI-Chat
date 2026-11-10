extends RefCounted

# Plan input "listen": subscribe to signals, recorded by the "events" observer.
#
#   {"at": 0, "listen": [{"path": "/root/Game", "signal": "level_completed"},
#                        {"path": "/root/Game/Player", "signal": "died"}]}
#   {"at": 0, "listen": {"clear": true}}       drop the records, keep the subscriptions
#   {"at": 0, "listen": {"disconnect": true}}  drop the subscriptions too
#
# Unlike the "probe" subscriptions, the reply says whether each signal bound right away: a path
# that does not resolve or a misspelled signal is reported, never silently quiet.
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Public Functions ---

func keys() -> Array[String]:
	return ["listen"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	var entries: Array = []
	if typeof(p_payload) == TYPE_ARRAY:
		entries = p_payload
	elif typeof(p_payload) == TYPE_DICTIONARY:
		entries = [p_payload]
	else:
		return {"kind": "listen", "at": p_index,
			"error": "payload must be an object or an array of objects"}

	var added: Array[Dictionary] = []
	for raw: Variant in entries:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = raw
		if bool(entry.get("clear", false)):
			p_context.events.clear_records()
		if bool(entry.get("disconnect", false)):
			p_context.events.unsubscribe_all()
		if not entry.has("path") or not entry.has("signal"):
			continue
		var sub: Dictionary = p_context.events.subscribe(p_context, str(entry.path), str(entry.signal))
		added.append({"path": str(sub.path), "signal": str(sub.signal),
			"bound": p_context.events.is_bound(sub), "error": str(sub.get("error", ""))})

	return {"kind": "listen", "at": p_index, "added": added,
		"count": p_context.events.subscription_count(), "error": ""}


func cleanup() -> void:
	# The subscriptions live in the shared EventLog, which this contract cannot reach: cleanup() is
	# called without a context. probe_node._exit_tree() unsubscribes them on the way out instead.
	pass
