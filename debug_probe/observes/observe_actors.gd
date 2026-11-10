extends RefCounted

# Watch "actors": every CharacterBody in the scene by name — position, velocity, ground contact.
#
# "pose" answers "where is the player"; this answers "where is everything else", which is what a
# check like "that enemy must never cross the wall" needs.
#
# Capability contract (duck typed, no base class): key() / collect().

const Frame := preload("res://debug_probe/core/frame.gd")

# --- Public Functions ---

func key() -> String:
	return "actors"


func collect(p_context) -> Variant:
	var out: Array[Dictionary] = []
	var scene: Node = p_context.tree().current_scene
	if scene == null:
		return out
	for cls: String in ["CharacterBody3D", "CharacterBody2D"]:
		for node: Node in scene.find_children("*", cls, true, false):
			out.append(_entry(node))
	return out

# --- Private Functions ---

# Name, class and motion of one body. Listed by node name: stable across frames, and readable in
# a report without a path lookup.
func _entry(p_body: Node) -> Dictionary:
	var d: Dictionary = {"name": str(p_body.name), "path": str(p_body.get_path())}
	if p_body is Node3D:
		d.pos = Frame.vec3(p_body.global_position)
	elif p_body is Node2D:
		d.pos = Frame.vec2(p_body.global_position)
	if p_body is CharacterBody3D:
		d.velocity = Frame.vec3(p_body.velocity)
		d.on_floor = p_body.is_on_floor()
		d.on_wall = p_body.is_on_wall()
	elif p_body is CharacterBody2D:
		d.velocity = Frame.vec2(p_body.velocity)
		d.on_floor = p_body.is_on_floor()
		d.on_wall = p_body.is_on_wall()
	return d
