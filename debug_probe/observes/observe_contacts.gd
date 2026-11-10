extends RefCounted

# Watch "contacts": what the player's body is touching right now, and — for every node added with
# the "contact" plan key — what that node is touching.
#
# This is the observer that stops a blocked test from turning into a false bug report: "the
# character did not move" and "the character was pushed into a wall" look identical in a position
# sample and completely different here.
#
# The player's report stays at the top level (player / count / blocked / truncated / items) so
# existing assertions keep working; subscriptions appear under "targets", keyed by node path.
# A wall is a StaticBody and cannot report anything itself: core/contact_probe.gd asks the physics
# space with the wall's own shapes instead, which is why only that branch can answer "is anything
# touching this wall".
#
# Capability contract (duck typed, no base class): key() / collect().

# --- Constants ---

const ContactProbe := preload("res://debug_probe/core/contact_probe.gd")
const PlayerFinder := preload("res://debug_probe/core/player_finder.gd")

# --- Public Functions ---

func key() -> String:
	return "contacts"


func collect(p_context) -> Variant:
	var player: Node = PlayerFinder.find(p_context)
	var out: Dictionary = {}
	if player == null:
		out = {"player": null, "kind": "none", "blocked": false, "count": 0,
			"truncated": false, "items": []}
	else:
		var report: Dictionary = ContactProbe.report(p_context, player)
		out = {
			"player": report.get("path", ""),
			"kind": report.get("kind", ""),
			"count": report.get("count", 0),
			"blocked": report.get("blocked", false),
			"truncated": report.get("truncated", false),
			"items": report.get("items", []),
		}
		if report.has("error"):
			out.error = report.error
	if not p_context.contact_targets.is_empty():
		out.targets = _targets(p_context)
	return out

# --- Private Functions ---

func _targets(p_context) -> Dictionary:
	var out: Dictionary = {}
	var root: Node = p_context.tree().root
	for path: String in p_context.contact_targets:
		var node: Node = root.get_node_or_null(path)
		if node == null:
			out[path] = {"path": path, "kind": "none", "count": 0, "blocked": false,
				"truncated": false, "items": [], "error": "no such node"}
			continue
		out[path] = ContactProbe.report(p_context, node)
	return out
