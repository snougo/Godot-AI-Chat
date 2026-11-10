extends RefCounted

# Contact reports for the "contact" plan key: who is touching this body right now.
#
# The engine reports contact in two different ways, so there are two branches:
#   CharacterBody -> the slide collisions of its last move_and_slide() (collider, normal, travel)
#   StaticBody / AnimatableBody / RigidBody -> cannot answer "who touches me" themselves, so their
#                    own collision shapes are pushed into the physics space to see what overlaps.
#                    Overlap is used for rigid bodies too, instead of contact_monitor: the monitor
#                    only starts recording after it is switched on, and a body at rest is asleep
#                    and reports nothing at all — while a wall or a crate sitting on the floor is
#                    exactly the case a test cares about. Overlap is read-only, so it never wakes
#                    or otherwise changes the game.
#
# Every report has the same shape:
#   {path, kind, count, blocked, truncated, items, error?}

# --- Constants ---

const Value := preload("res://debug_probe/core/value.gd")

const MAX_ITEMS: int = 8
# A static body is measured with its shapes grown by this much: two surfaces resting exactly on
# each other do not overlap, so without a margin "touching" would read as "not touching". The
# price is that a wall also reports the floor it stands on — filter by collider, not by count.
const TOUCH_MARGIN: float = 0.05
# 2D physics counts in pixels, where 0.05 would be no margin at all (it is below the smallest
# distance the solver resolves): half a pixel is the 2D equivalent of the 0.05 m above.
const TOUCH_MARGIN_2D: float = 0.5
const MAX_MASK: int = 0xFFFFFFFF

# --- Public Functions ---

static func report(p_context, p_node: Node) -> Dictionary:
	if p_node == null:
		return {"path": "<null>", "kind": "none", "count": 0, "blocked": false,
			"truncated": false, "items": [], "error": "no such node"}
	if p_node is CharacterBody3D or p_node is CharacterBody2D:
		return _character(p_node)
	if p_node is StaticBody3D or p_node is AnimatableBody3D \
			or p_node is StaticBody2D or p_node is AnimatableBody2D:
		return _overlap(p_context, p_node, "static")
	if p_node is RigidBody3D or p_node is RigidBody2D:
		return _overlap(p_context, p_node, "rigid")
	return _envelope(p_node, "unsupported", "cannot report contacts; observe the body that moves "
		+ "into it, or use a \"near\" query")

# --- Private Functions ---

static func _character(p_node: Node) -> Dictionary:
	var items: Array[Dictionary] = []
	var count: int = 0
	if p_node is CharacterBody3D:
		var body: CharacterBody3D = p_node
		count = body.get_slide_collision_count()
		for i: int in mini(count, MAX_ITEMS):
			items.append(_slide3(body.get_slide_collision(i)))
	else:
		var body2: CharacterBody2D = p_node
		count = body2.get_slide_collision_count()
		for i: int in mini(count, MAX_ITEMS):
			items.append(_slide2(body2.get_slide_collision(i)))
	return _envelope(p_node, "character", "", count, items)


static func _overlap(p_context, p_node: Node, p_kind: String) -> Dictionary:
	var items: Array[Dictionary] = []
	# Every shape query stops at MAX_ITEMS, and when it does the real number is unknown — not just
	# the list. Remember that, because no count can express it.
	var capped: bool = false
	if p_node is CollisionObject3D:
		var space: PhysicsDirectSpaceState3D = _space_3d(p_context)
		if space == null:
			return _envelope(p_node, p_kind, "no 3D world in this viewport")
		var self_rid: RID = (p_node as CollisionObject3D).get_rid()
		for shape_node: Node in p_node.find_children("*", "CollisionShape3D", true, false):
			var collision: CollisionShape3D = shape_node
			if collision.shape == null:
				continue
			var params := PhysicsShapeQueryParameters3D.new()
			params.shape = _grown3(collision.shape)
			params.transform = collision.global_transform
			params.collision_mask = MAX_MASK
			params.collide_with_bodies = true
			params.collide_with_areas = false
			params.exclude = [self_rid]
			var found3: Array[Dictionary] = space.intersect_shape(params, MAX_ITEMS)
			capped = capped or found3.size() >= MAX_ITEMS
			for hit: Dictionary in found3:
				items.append({"collider": _path_of(hit.get("collider", null))})
		var unique3: Array[Dictionary] = _unique(items)
		return _envelope(p_node, p_kind, "", unique3.size(), unique3, capped)

	var space2: PhysicsDirectSpaceState2D = _space_2d(p_context)
	if space2 == null:
		return _envelope(p_node, p_kind, "no 2D world in this viewport")
	var self_rid2: RID = (p_node as CollisionObject2D).get_rid()
	for shape_node2: Node in p_node.find_children("*", "CollisionShape2D", true, false):
		var collision2: CollisionShape2D = shape_node2
		if collision2.shape == null:
			continue
		var params2 := PhysicsShapeQueryParameters2D.new()
		params2.shape = _grown2(collision2.shape)
		params2.transform = collision2.global_transform
		params2.collision_mask = MAX_MASK
		params2.collide_with_bodies = true
		params2.collide_with_areas = false
		params2.exclude = [self_rid2]
		var found2: Array[Dictionary] = space2.intersect_shape(params2, MAX_ITEMS)
		capped = capped or found2.size() >= MAX_ITEMS
		for hit2: Dictionary in found2:
			items.append({"collider": _path_of(hit2.get("collider", null))})
	var unique2: Array[Dictionary] = _unique(items)
	return _envelope(p_node, p_kind, "", unique2.size(), unique2, capped)

# --- Shared helpers ---

# count is what the engine reported (may exceed the items we kept), so truncation stays visible.
# p_truncated covers the case a count cannot express: one shape query hit its own result cap, so
# even count is only a lower bound.
static func _envelope(p_node: Node, p_kind: String, p_error: String = "",
		p_count: int = -1, p_items: Array[Dictionary] = [] as Array[Dictionary],
		p_truncated: bool = false) -> Dictionary:
	var count: int = p_items.size() if p_count < 0 else p_count
	var kept: Array[Dictionary] = []
	for item: Dictionary in p_items:
		if kept.size() >= MAX_ITEMS:
			break
		kept.append(item)
	var out: Dictionary = {
		"path": _path_of(p_node),
		"kind": p_kind,
		"count": count,
		"blocked": count > 0,
		"truncated": p_truncated or count > kept.size(),
		"items": kept,
	}
	if not p_error.is_empty():
		out.error = p_error
	return out


static func _slide3(p_hit: KinematicCollision3D) -> Dictionary:
	return {
		"collider": _path_of(p_hit.get_collider()),
		"normal": Value.simplify(p_hit.get_normal()),
		"position": Value.simplify(p_hit.get_position()),
		"travel": Value.simplify(p_hit.get_travel()),
		"depth": Value.simplify(p_hit.get_depth()),
	}


static func _slide2(p_hit: KinematicCollision2D) -> Dictionary:
	return {
		"collider": _path_of(p_hit.get_collider()),
		"normal": Value.simplify(p_hit.get_normal()),
		"position": Value.simplify(p_hit.get_position()),
		"travel": Value.simplify(p_hit.get_travel()),
		"depth": Value.simplify(p_hit.get_depth()),
	}


# A body with several collision shapes hits the query once per shape: report it once. Every
# distinct collider is returned — _envelope() caps the list, so the real count stays countable.
static func _unique(p_items: Array[Dictionary]) -> Array[Dictionary]:
	var seen: Dictionary = {}
	var out: Array[Dictionary] = []
	for item: Dictionary in p_items:
		var key: String = str(item.get("collider", ""))
		if seen.has(key):
			continue
		seen[key] = true
		out.append(item)
	return out


static func _grown3(p_shape: Shape3D) -> Shape3D:
	var copy: Shape3D = p_shape.duplicate()
	if copy is SphereShape3D:
		(copy as SphereShape3D).radius += TOUCH_MARGIN
	elif copy is CapsuleShape3D:
		(copy as CapsuleShape3D).radius += TOUCH_MARGIN
	elif copy is BoxShape3D:
		(copy as BoxShape3D).size += Vector3.ONE * TOUCH_MARGIN * 2.0
	elif copy is CylinderShape3D:
		(copy as CylinderShape3D).radius += TOUCH_MARGIN
	return copy


static func _grown2(p_shape: Shape2D) -> Shape2D:
	var copy: Shape2D = p_shape.duplicate()
	if copy is CircleShape2D:
		(copy as CircleShape2D).radius += TOUCH_MARGIN_2D
	elif copy is RectangleShape2D:
		(copy as RectangleShape2D).size += Vector2.ONE * TOUCH_MARGIN_2D * 2.0
	elif copy is CapsuleShape2D:
		(copy as CapsuleShape2D).radius += TOUCH_MARGIN_2D
	return copy


static func _space_3d(p_context) -> PhysicsDirectSpaceState3D:
	var world: World3D = p_context.viewport().find_world_3d()
	return world.direct_space_state if world != null else null


static func _space_2d(p_context) -> PhysicsDirectSpaceState2D:
	var world: World2D = p_context.viewport().find_world_2d()
	return world.direct_space_state if world != null else null


static func _path_of(p_object: Object) -> String:
	if p_object == null:
		return "<null>"
	if p_object is Node:
		return str((p_object as Node).get_path())
	return "%s#%d" % [p_object.get_class(), p_object.get_instance_id()]
