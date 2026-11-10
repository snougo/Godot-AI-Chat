extends RefCounted

# Physics-space queries for the "query" plan key (L4): rays, sphere neighbourhoods, and the
# body-width fan scan.
#
# Observations can only read node properties. Whether a wall stands between the player and an
# enemy, or what the player is actually standing on, lives in the physics server, not on a node —
# that is what this file asks about.
#
# 3D and 2D are both supported; the dimension comes from the node the query starts at
# (Node3D -> 3D, Node2D -> 2D) or from the length of an explicit "point".
#
# Known trap: PhysicsRayQueryParameters*.create() leaves collide_with_areas off, so a ray built
# that way never reports an Area3D. Pass "areas": true when the question is about triggers.
#
# Everything here is static: the runner calls it without keeping an instance.

# --- Constants ---

const Value := preload("res://debug_probe/core/value.gd")
const SpaceScan := preload("res://debug_probe/core/space_scan.gd")

const DEFAULT_LENGTH: float = 10.0
const DEFAULT_RADIUS: float = 4.0
const MAX_NEAR_RESULTS: int = 32
const MAX_MASK: int = 0xFFFFFFFF

# --- Public Functions ---

static func run(p_context, p_request: Dictionary) -> Dictionary:
	var label: String = str(p_request.get("as", "query"))
	var kind: String = str(p_request.get("kind", "ray"))
	var origin: Dictionary = _origin(p_context, p_request)
	if not bool(origin.get("ok", false)):
		return {"kind": "query", "as": label, "error": str(origin.get("error", "bad origin"))}
	match kind:
		"ray":
			return _ray(p_context, p_request, label, origin)
		"near":
			return _near(p_context, p_request, label, origin)
		"scan":
			# Body-width fan scan: lives in its own file (core/space_scan.gd) because it is the one
			# query that answers a decision rather than a shape. The origin is resolved here, the
			# way all three kinds share it.
			return SpaceScan.run(p_context, p_request, label, origin)
	return {"kind": "query", "as": label,
		"error": "unknown kind '%s' (supported: ray, near, scan)" % kind}

# --- Private Functions ---

# Where the query starts, and in which dimension.
static func _origin(p_context, p_request: Dictionary) -> Dictionary:
	var node: Node = null
	if p_request.has("from"):
		node = p_context.tree().root.get_node_or_null(str(p_request.from))
		if node == null:
			return {"ok": false, "error": "no such node: %s" % str(p_request.from)}
	if node is Node3D:
		var p3: Vector3 = (node as Node3D).global_position + _vec3(p_request.get("offset", []))
		return {"ok": true, "dim": 3, "node": node, "point": p3}
	if node is Node2D:
		var p2: Vector2 = (node as Node2D).global_position + _vec2(p_request.get("offset", []))
		return {"ok": true, "dim": 2, "node": node, "point": p2}
	if p_request.has("point"):
		var raw: Variant = p_request.point
		var arr: Array = raw if typeof(raw) == TYPE_ARRAY else []
		if arr.size() >= 3:
			return {"ok": true, "dim": 3, "node": null,
				"point": Vector3(float(arr[0]), float(arr[1]), float(arr[2]))}
		if arr.size() == 2:
			return {"ok": true, "dim": 2, "node": null,
				"point": Vector2(float(arr[0]), float(arr[1]))}
	return {"ok": false,
		"error": "need a Node3D/Node2D \"from\", or a \"point\" of 2 or 3 numbers"}


static func _ray(p_context, p_request: Dictionary, p_label: String, p_origin: Dictionary) -> Dictionary:
	var length: float = float(p_request.get("length", DEFAULT_LENGTH))
	var mask: int = int(p_request.get("mask", MAX_MASK))
	var areas: bool = bool(p_request.get("areas", false))
	var exclude: Array[RID] = _exclude(p_context, p_origin, p_request)
	var result: Dictionary = {"kind": "query", "as": p_label, "type": "ray", "hit": false}
	if int(p_origin.dim) == 3:
		var space: PhysicsDirectSpaceState3D = _space_3d(p_context)
		if space == null:
			result.error = "no 3D world in this viewport"
			return result
		var from3: Vector3 = p_origin.point
		var to3: Vector3 = from3 + _direction3(p_origin, p_request).normalized() * length
		# create() leaves areas off: a ray has to answer the same way "near" and "scan" do, or a
		# trigger is invisible to one query kind and visible to another.
		var query3 := PhysicsRayQueryParameters3D.create(from3, to3, mask, exclude)
		query3.collide_with_areas = areas
		var hit: Dictionary = space.intersect_ray(query3)
		result.from = Value.simplify(from3)
		result.to = Value.simplify(to3)
		if hit.is_empty():
			return result
		result.hit = true
		result.collider = _path_of(hit.get("collider", null))
		result.distance = snappedf(from3.distance_to(hit.position), 0.001)
		result.point = Value.simplify(hit.position)
		result.normal = Value.simplify(hit.normal)
		return result

	var space2: PhysicsDirectSpaceState2D = _space_2d(p_context)
	if space2 == null:
		result.error = "no 2D world in this viewport"
		return result
	var from2: Vector2 = p_origin.point
	var to2: Vector2 = from2 + _direction2(p_origin, p_request).normalized() * length
	var query2 := PhysicsRayQueryParameters2D.create(from2, to2, mask, exclude)
	query2.collide_with_areas = areas
	var hit2: Dictionary = space2.intersect_ray(query2)
	result.from = Value.simplify(from2)
	result.to = Value.simplify(to2)
	if hit2.is_empty():
		return result
	result.hit = true
	result.collider = _path_of(hit2.get("collider", null))
	result.distance = snappedf(from2.distance_to(hit2.position), 0.001)
	result.point = Value.simplify(hit2.position)
	result.normal = Value.simplify(hit2.normal)
	return result


static func _near(p_context, p_request: Dictionary, p_label: String, p_origin: Dictionary) -> Dictionary:
	var radius: float = float(p_request.get("radius", DEFAULT_RADIUS))
	var mask: int = int(p_request.get("mask", MAX_MASK))
	var areas: bool = bool(p_request.get("areas", false))
	var exclude: Array[RID] = _exclude(p_context, p_origin, p_request)
	var result: Dictionary = {"kind": "query", "as": p_label, "type": "near",
		"radius": snappedf(radius, 0.001), "count": 0, "truncated": false, "bodies": []}
	var bodies: Array[Dictionary] = []

	if int(p_origin.dim) == 3:
		var space: PhysicsDirectSpaceState3D = _space_3d(p_context)
		if space == null:
			result.error = "no 3D world in this viewport"
			return result
		var from3: Vector3 = p_origin.point
		var sphere := SphereShape3D.new()
		sphere.radius = radius
		var params := PhysicsShapeQueryParameters3D.new()
		params.shape = sphere
		params.transform = Transform3D(Basis(), from3)
		params.collision_mask = mask
		params.collide_with_bodies = true
		params.collide_with_areas = areas
		params.exclude = exclude
		var hits: Array[Dictionary] = space.intersect_shape(params, MAX_NEAR_RESULTS)
		for hit: Dictionary in hits:
			bodies.append(_nearest(from3, hit.get("collider", null)))
		result.truncated = hits.size() >= MAX_NEAR_RESULTS
	else:
		var space2: PhysicsDirectSpaceState2D = _space_2d(p_context)
		if space2 == null:
			result.error = "no 2D world in this viewport"
			return result
		var from2: Vector2 = p_origin.point
		var circle := CircleShape2D.new()
		circle.radius = radius
		var params2 := PhysicsShapeQueryParameters2D.new()
		params2.shape = circle
		params2.transform = Transform2D(0.0, from2)
		params2.collision_mask = mask
		params2.collide_with_bodies = true
		params2.collide_with_areas = areas
		params2.exclude = exclude
		var hits2: Array[Dictionary] = space2.intersect_shape(params2, MAX_NEAR_RESULTS)
		for hit: Dictionary in hits2:
			bodies.append(_nearest(from2, hit.get("collider", null)))
		result.truncated = hits2.size() >= MAX_NEAR_RESULTS

	# A body with several shapes hits the sphere several times: report it once, nearest first.
	var unique: Dictionary = {}
	for body: Dictionary in bodies:
		unique[str(body.path)] = body
	var list: Array[Dictionary] = []
	for key: Variant in unique:
		list.append(unique[key])
	list.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.distance < b.distance)
	result.bodies = list
	result.count = list.size()
	return result


# One entry of a "near" result: who it is, how far its origin is, which layers it lives on.
static func _nearest(p_from: Variant, p_collider: Variant) -> Dictionary:
	var collider: Object = p_collider
	if collider == null:
		return {"path": "<null>", "class": "", "distance": -1.0, "layer": 0}
	var distance: float = -1.0
	if collider is Node3D and p_from is Vector3:
		distance = snappedf((p_from as Vector3).distance_to((collider as Node3D).global_position), 0.001)
	elif collider is Node2D and p_from is Vector2:
		distance = snappedf((p_from as Vector2).distance_to((collider as Node2D).global_position), 0.001)
	var layer: int = 0
	if collider is CollisionObject3D:
		layer = (collider as CollisionObject3D).collision_layer
	elif collider is CollisionObject2D:
		layer = (collider as CollisionObject2D).collision_layer
	return {
		"path": _path_of(collider),
		"class": collider.get_class(),
		"distance": distance,
		"layer": layer,
	}

# --- Shared helpers ---

static func _space_3d(p_context) -> PhysicsDirectSpaceState3D:
	var world: World3D = p_context.viewport().find_world_3d()
	return world.direct_space_state if world != null else null


static func _space_2d(p_context) -> PhysicsDirectSpaceState2D:
	var world: World2D = p_context.viewport().find_world_2d()
	return world.direct_space_state if world != null else null


# The body the query starts inside must not block it: exclude the origin node by default, and
# accept extra "exclude" node paths.
static func _exclude(p_context, p_origin: Dictionary, p_request: Dictionary) -> Array[RID]:
	var out: Array[RID] = []
	var node: Variant = p_origin.get("node", null)
	if node is CollisionObject3D:
		out.append((node as CollisionObject3D).get_rid())
	elif node is CollisionObject2D:
		out.append((node as CollisionObject2D).get_rid())
	for raw: Variant in p_request.get("exclude", []):
		var excluded: Node = p_context.tree().root.get_node_or_null(str(raw))
		if excluded is CollisionObject3D:
			out.append((excluded as CollisionObject3D).get_rid())
		elif excluded is CollisionObject2D:
			out.append((excluded as CollisionObject2D).get_rid())
	return out


# A missing direction means "where the origin node is looking": -Z in 3D, +X in 2D — the same
# convention "scan" uses (core/space_scan.gd), so a query does not change meaning with its kind.
# A point-only origin has no facing: ask for a downward probe explicitly with "direction": [0,-1,0].
static func _direction3(p_origin: Dictionary, p_request: Dictionary) -> Vector3:
	if p_request.has("direction"):
		var named: Vector3 = _vec3(p_request.direction)
		if not named.is_zero_approx():
			return named
	var node: Variant = p_origin.get("node", null)
	if node is Node3D:
		return -(node as Node3D).global_transform.basis.z
	return Vector3(0.0, 0.0, -1.0)


static func _direction2(p_origin: Dictionary, p_request: Dictionary) -> Vector2:
	if p_request.has("direction"):
		var named: Vector2 = _vec2(p_request.direction)
		if not named.is_zero_approx():
			return named
	var node: Variant = p_origin.get("node", null)
	if node is Node2D:
		return (node as Node2D).global_transform.x
	return Vector2(1.0, 0.0)


static func _vec3(p_value: Variant) -> Vector3:
	if typeof(p_value) == TYPE_ARRAY and (p_value as Array).size() >= 3:
		var arr: Array = p_value
		return Vector3(float(arr[0]), float(arr[1]), float(arr[2]))
	return Vector3.ZERO


static func _vec2(p_value: Variant) -> Vector2:
	if typeof(p_value) == TYPE_ARRAY and (p_value as Array).size() >= 2:
		var arr: Array = p_value
		return Vector2(float(arr[0]), float(arr[1]))
	return Vector2.ZERO


static func _path_of(p_object: Object) -> String:
	if p_object == null:
		return "<null>"
	if p_object is Node:
		return str((p_object as Node).get_path())
	return "%s#%d" % [p_object.get_class(), p_object.get_instance_id()]
