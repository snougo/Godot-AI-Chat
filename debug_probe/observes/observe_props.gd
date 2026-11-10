extends RefCounted

# Watch "props": the node properties subscribed to by the "probe" plan key.
#
# The point of this observer is that it needs no new file per project: one game exposes HP in a
# script variable, another in a dictionary on an autoload, and both are reachable with
#   {"at": 0, "probe": [{"path": "/root/Game/Player", "props": ["hp"]}]}
#
# Values come back simplified (vectors as arrays, objects as paths), see core/value.gd.
#
# Capability contract (duck typed, no base class): key() / collect().

# --- Constants ---

const SamplePath := preload("res://debug_probe/core/sample_path.gd")
const Value := preload("res://debug_probe/core/value.gd")

# --- Public Functions ---

func key() -> String:
	return "props"


func collect(p_context) -> Variant:
	var out: Dictionary = {}
	if p_context.probe_targets.is_empty():
		return {"error": "nothing subscribed; use the \"probe\" plan key first"}
	var root: Node = p_context.tree().root
	for target: Dictionary in p_context.probe_targets:
		var path: String = str(target.get("path", ""))
		var node: Node = root.get_node_or_null(path)
		if node == null:
			out[path] = {"error": "no such node"}
			continue
		var read: Dictionary = {}
		for name: Variant in target.get("props", []):
			read[str(name)] = _read(node, str(name))
		out[path] = read
	return out

# --- Private Functions ---

# A property name, optionally with a sub-path: "hp", "velocity", "velocity.x", "stats.kills".
# Sub-paths are split on dots (node paths use slashes, property paths use dots). The walk itself
# lives in core/sample_path.gd and also follows Object properties, so a sub-path may step through a
# Resource or into another node.
func _read(p_node: Node, p_name: String) -> Variant:
	var segments: Array = p_name.split(".", false)
	if segments.is_empty():
		return null
	var head: String = str(segments[0])
	var value: Variant = _property(p_node, head)
	if segments.size() == 1:
		return Value.simplify(value)
	var rest: Dictionary = SamplePath.walk(value, segments.slice(1))
	if not bool(rest.get("found", false)):
		return null
	return Value.simplify(rest.value)


# The property's value, or null when the node has no such property.
func _property(p_node: Node, p_name: String) -> Variant:
	for entry: Dictionary in p_node.get_property_list():
		if str(entry.get("name", "")) == p_name:
			return p_node.get(p_name)
	return null
