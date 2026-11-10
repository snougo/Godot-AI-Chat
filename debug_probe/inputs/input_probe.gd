extends RefCounted

# Plan input "probe": subscribe to node properties, read back by the "props" observer.
#
#   {"at": 0, "probe": [{"path": "/root/Game/Player", "props": ["hp", "state", "velocity"]},
#                       {"path": "/root/Game/GameState", "props": ["score"]}]}
#   {"at": 0, "probe": {"clear": true}}      forget every earlier subscription
#
# Subscriptions accumulate and survive across steps (an idle release must not wipe them), so this
# is a setup action, not a per-frame one. Reading private members (_hp) works on purpose: GDScript
# script variables are all properties, and a probe that can only see @export values is useless on
# a project that was written before the probe existed.
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Public Functions ---

func keys() -> Array[String]:
	return ["probe"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	var entries: Array = []
	if typeof(p_payload) == TYPE_ARRAY:
		entries = p_payload
	elif typeof(p_payload) == TYPE_DICTIONARY:
		entries = [p_payload]
	else:
		return {"kind": "probe", "at": p_index,
			"error": "payload must be an object or an array of objects"}

	var registered: Array[Dictionary] = []
	for raw: Variant in entries:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var entry: Dictionary = raw
		if bool(entry.get("clear", false)):
			p_context.probe_targets.clear()
		if not entry.has("path"):
			continue
		var path: String = str(entry.path)
		var props: Array[String] = []
		for name: Variant in entry.get("props", []):
			props.append(str(name))
		_register(p_context, path, props)
		registered.append({"path": path, "props": props,
			"resolved": p_context.tree().root.get_node_or_null(path) != null})

	return {"kind": "probe", "at": p_index, "targets": registered,
		"count": p_context.probe_targets.size(), "error": ""}


func cleanup() -> void:
	pass

# --- Private Functions ---

# Merges into an existing subscription for the same node instead of adding a duplicate read.
func _register(p_context, p_path: String, p_props: Array[String]) -> void:
	for target: Dictionary in p_context.probe_targets:
		if str(target.get("path", "")) != p_path:
			continue
		var existing: Array = target.get("props", [])
		for name: String in p_props:
			if not existing.has(name):
				existing.append(name)
		target["props"] = existing
		return
	p_context.probe_targets.append({"path": p_path, "props": p_props})
