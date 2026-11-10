extends RefCounted

# One place that answers "which node is the player", shared by every observer that reports on the
# controlled body.
#
# Order matters, and the order was learned the hard way on a real project (the Godot TPS demo):
# its player is spawned at runtime under a generated name ("1"), is not in any group, and a
# CharacterBody3D enemy comes first in the tree — so "first CharacterBody" pointed at a robot.
#
#   1. the configured path                       explicit always wins
#   2. the "player" group                        cheap and conventional
#   3. the body that owns the active camera       an FPS/TPS rig always has one; survives renaming
#   4. a body whose name contains "player"        last structural hint
#   5. the first CharacterBody in the scene       better than nothing
#
# Static and cache-free on purpose: the lookups are cheap, and a cache that outlives a scene change
# is a bug waiting to happen. Order in this file is "player's own root first": the camera walk stops
# at the nearest CharacterBody ancestor, and the `current_scene` fallbacks only run when it fails.

# --- Public Functions ---

static func find(p_context) -> Node:
	var configured: NodePath = p_context.settings.get("player_path", ^"")
	if not configured.is_empty():
		var node: Node = p_context.host.get_node_or_null(configured)
		if node != null:
			return node
	for candidate: Node in p_context.tree().get_nodes_in_group("player"):
		return candidate
	var from_camera: Node = _camera_owner(p_context)
	if from_camera != null:
		return from_camera
	var scene: Node = p_context.tree().current_scene
	if scene == null:
		return null
	var named: Node = _first_named(scene, "player")
	if named != null:
		return named
	for cls: String in ["CharacterBody3D", "CharacterBody2D"]:
		var found: Array[Node] = scene.find_children("*", cls, true, false)
		if not found.is_empty():
			return found[0]
	return null

# --- Private Functions ---

# The nearest CharacterBody above the active camera: that is the body the player is looking out of.
static func _camera_owner(p_context) -> Node:
	var cam: Camera3D = p_context.viewport().get_camera_3d()
	if cam == null:
		return null
	var node: Node = cam
	var root: Node = p_context.tree().root
	while node != null and node != root:
		if node is CharacterBody3D or node is CharacterBody2D:
			return node
		node = node.get_parent()
	return null


static func _first_named(p_scene: Node, p_fragment: String) -> Node:
	for cls: String in ["CharacterBody3D", "CharacterBody2D"]:
		for candidate: Node in p_scene.find_children("*", cls, true, false):
			if str(candidate.name).to_lower().contains(p_fragment):
				return candidate
	return null
