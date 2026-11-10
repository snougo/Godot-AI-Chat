extends RefCounted

# Body-width fan scan for the "scan" kind of the "query" plan key (L4).
#
# A ray answers "is anything along this line" — the wrong question for a character with a body.
# An obstacle poking out of the roadside slips past a ray that happens to miss it and blocks a ray
# that happens to hit it, and neither answer says how to get around: the caller reads "blocked"
# as "this road is closed" and turns on the spot.
#
# So this scan asks the other question: for each heading in a fan around the player, how far can
# MY BODY move before it touches something. With "radius" > 0 the per-heading test is a swept
# capsule (3D) or circle (2D) the width of the caller, so "free" means "the character fits"; with
# "radius": 0 it degrades to thin rays for callers who really want centre lines.
#
# What comes out is a decision, not geometry:
#   open_spans   angular ranges the body can walk through (0 = straight ahead, positive = right)
#   widest       the widest of them
#   steer        a heading inside it, plus a world-space waypoint to head for
#   forward      what straight ahead looks like, always present
#   stuck        bodies the body shape already overlaps at the start
#
# Angles are degrees, positive = clockwise seen from above (2D: clockwise on screen). A span is
# reported as the outer edges of the rays it holds, so its width is (rays in it) * step and a lone
# free ray still reports a non-zero span; a span that touches the window edge means the opening
# continues beyond the scanned range.
#
# The "stuck" list exists because a cast_motion ignores shapes the body already overlaps (engine
# documented behaviour): without this check a character wedged into a pillar reads as "all clear",
# which is exactly the false negative this file was written to remove.
#
# Everything here is static: the runner calls it without keeping an instance.

# --- Constants ---

const Value := preload("res://debug_probe/core/value.gd")

const DEFAULT_SPREAD: float = 180.0
const DEFAULT_STEP: float = 10.0
const DEFAULT_LENGTH: float = 6.0
const DEFAULT_RADIUS: float = 0.35
const DEFAULT_HEIGHT: float = 1.8
const DEFAULT_MASK: int = 0xFFFFFFFF

const MIN_STEP: float = 1.0
const MAX_SPREAD: float = 359.0
const MAX_RAYS: int = 180
const EPSILON: float = 0.001
# The "already overlapping" test runs on a slightly lifted, slightly shrunk body: a character
# standing on the floor is touching it, not wedged inside it.
const TOUCH_LIFT: float = 0.05
const TOUCH_SHRINK: float = 0.05
# The collider of a blocked heading is read one hair past the safe fraction: exactly on the surface
# the shape only touches, and an overlap query there would answer "nothing".
const PROBE_MARGIN: float = 0.02
# 2D physics counts in pixels, where the two margins above are no margin at all: the 2D equivalents
# have to be magnitudes, or "already stuck" and "just past the surface" silently stop working.
const TOUCH_SHRINK_2D: float = 0.5
const PROBE_MARGIN_2D: float = 0.5
const MAX_STUCK: int = 8

# --- Public Functions ---

# p_origin is the dict space_query._origin() resolved: {dim, point, node}.
static func run(p_context, p_request: Dictionary, p_label: String, p_origin: Dictionary) -> Dictionary:
	var plan: Dictionary = _plan(p_request)
	var radius: float = float(plan.radius)
	var out: Dictionary = {
		"kind": "query", "as": p_label, "type": "scan",
		"from": Value.simplify(p_origin.get("point", null)),
		"spread": snappedf(float(plan.spread), 0.001),
		"step": snappedf(float(plan.step), 0.001),
		"ray_count": (plan.angles as Array).size(),
		"length": snappedf(float(plan.length), 0.001),
		"need": snappedf(float(plan.need), 0.001),
		"radius": snappedf(radius, 0.001),
		# A thin-ray scan cannot answer "am I inside something": no body, no overlap to report.
		"stuck_checked": radius > 0.0,
	}
	var exclude: Array[RID] = _exclude(p_context, p_origin, p_request)
	var rows: Array[Dictionary] = []
	if int(p_origin.get("dim", 3)) == 3:
		var space: PhysicsDirectSpaceState3D = _space_3d(p_context)
		if space == null:
			out.error = "no 3D world in this viewport"
			return out
		var point: Vector3 = p_origin.point
		var base: Vector3 = _direction_3d(p_origin, p_request).normalized()
		var up: Vector3 = _axis(p_request.get("up", [0.0, 1.0, 0.0]))
		out.height = snappedf(float(plan.height), 0.001)
		rows = _scan_3d(space, point, base, up, exclude, p_request, plan)
		out.stuck_with = _stuck_3d(space, point, up, exclude, p_request, plan)
		_summarize(out, rows, plan, {"dim": 3, "point": point, "base": base, "up": up})
	else:
		var space2: PhysicsDirectSpaceState2D = _space_2d(p_context)
		if space2 == null:
			out.error = "no 2D world in this viewport"
			return out
		var point2: Vector2 = p_origin.point
		var base2: Vector2 = _direction_2d(p_origin, p_request).normalized()
		rows = _scan_2d(space2, point2, base2, exclude, p_request, plan)
		out.stuck_with = _stuck_2d(space2, point2, exclude, p_request, plan)
		_summarize(out, rows, plan, {"dim": 2, "point": point2, "base": base2, "up": Vector3.UP})
	var stuck: Array = out.stuck_with
	out.stuck = not stuck.is_empty()
	if bool(p_request.get("detail", false)):
		out.rays = rows
	return out

# --- Private Functions ---

# Request fields, clamped into a shape the rest of the file can trust. The ray count follows from
# spread / step, and the step is recomputed from the count so 0 is always exactly one heading.
static func _plan(p_request: Dictionary) -> Dictionary:
	var spread: float = clampf(float(p_request.get("spread", DEFAULT_SPREAD)), 0.0, MAX_SPREAD)
	var wanted: float = maxf(float(p_request.get("step", DEFAULT_STEP)), MIN_STEP)
	var count: int = 1
	if spread > 0.0:
		count = clampi(int(floor(spread / wanted)) + 1, 2, MAX_RAYS)
	var step: float = spread / float(maxi(count - 1, 1))
	var angles: Array[float] = []
	for index: int in count:
		angles.append(-spread / 2.0 + step * float(index))
	var length: float = maxf(float(p_request.get("length", DEFAULT_LENGTH)), EPSILON)
	return {
		"spread": spread,
		"step": step,
		"angles": angles,
		"length": length,
		"need": clampf(float(p_request.get("need", length)), 0.0, length),
		"radius": maxf(float(p_request.get("radius", DEFAULT_RADIUS)), 0.0),
		"height": maxf(float(p_request.get("height", DEFAULT_HEIGHT)), 0.01),
		"mask": int(p_request.get("mask", DEFAULT_MASK)),
	}


static func _scan_3d(p_space: PhysicsDirectSpaceState3D, p_point: Vector3, p_base: Vector3,
		p_up: Vector3, p_exclude: Array[RID], p_request: Dictionary,
		p_plan: Dictionary) -> Array[Dictionary]:
	var radius: float = float(p_plan.radius)
	var detail: bool = bool(p_request.get("detail", false))
	var areas: bool = bool(p_request.get("areas", false))
	var body: bool = radius > 0.0
	var body_height: float = maxf(float(p_plan.height), radius * 2.0)
	var params := PhysicsShapeQueryParameters3D.new()
	if body:
		var capsule := CapsuleShape3D.new()
		capsule.radius = radius
		capsule.height = body_height
		params.shape = capsule
		params.collision_mask = int(p_plan.mask)
		params.collide_with_bodies = true
		params.collide_with_areas = areas
		params.exclude = p_exclude
	# The body stands on the origin: its centre is half a body up. Thin rays start at the origin.
	var center: Vector3 = p_point + p_up * (body_height / 2.0)
	var rows: Array[Dictionary] = []
	for angle: float in (p_plan.angles as Array[float]):
		var heading: Vector3 = p_base.rotated(p_up, -deg_to_rad(angle)).normalized()
		if body:
			rows.append(_sweep_3d(p_space, params, center, heading, angle, p_plan, detail))
		else:
			rows.append(_cast_3d(p_space, p_point, heading, angle, p_plan, p_exclude, areas, detail))
	return rows


static func _scan_2d(p_space: PhysicsDirectSpaceState2D, p_point: Vector2, p_base: Vector2,
		p_exclude: Array[RID], p_request: Dictionary,
		p_plan: Dictionary) -> Array[Dictionary]:
	var radius: float = float(p_plan.radius)
	var detail: bool = bool(p_request.get("detail", false))
	var areas: bool = bool(p_request.get("areas", false))
	var body: bool = radius > 0.0
	var params := PhysicsShapeQueryParameters2D.new()
	if body:
		var circle := CircleShape2D.new()
		circle.radius = radius
		params.shape = circle
		params.collision_mask = int(p_plan.mask)
		params.collide_with_bodies = true
		params.collide_with_areas = areas
		params.exclude = p_exclude
	var rows: Array[Dictionary] = []
	for angle: float in (p_plan.angles as Array[float]):
		var heading: Vector2 = p_base.rotated(deg_to_rad(angle)).normalized()
		if body:
			rows.append(_sweep_2d(p_space, params, p_point, heading, angle, p_plan, detail))
		else:
			rows.append(_cast_2d(p_space, p_point, heading, angle, p_plan, p_exclude, areas, detail))
	return rows


# One thin-ray heading: the same answer "ray" gives, one per heading.
static func _cast_3d(p_space: PhysicsDirectSpaceState3D, p_from: Vector3, p_heading: Vector3,
		p_angle: float, p_plan: Dictionary, p_exclude: Array[RID],
		p_areas: bool, p_detail: bool) -> Dictionary:
	var length: float = float(p_plan.length)
	# create() leaves areas off while the body branch reads "areas": without this line the flag
	# would silently mean two different things depending on "radius".
	var query := PhysicsRayQueryParameters3D.create(
		p_from, p_from + p_heading * length, int(p_plan.mask), p_exclude)
	query.collide_with_areas = p_areas
	var hit: Dictionary = p_space.intersect_ray(query)
	var row: Dictionary = {"angle": snappedf(p_angle, 0.001), "distance": snappedf(length, 0.001)}
	if hit.is_empty():
		return row
	row.distance = snappedf(p_from.distance_to(hit.position), 0.001)
	row.collider = _path_of(hit.get("collider", null))
	if p_detail:
		row.point = Value.simplify(hit.position)
		row.normal = Value.simplify(hit.normal)
	return row


static func _cast_2d(p_space: PhysicsDirectSpaceState2D, p_from: Vector2, p_heading: Vector2,
		p_angle: float, p_plan: Dictionary, p_exclude: Array[RID],
		p_areas: bool, p_detail: bool) -> Dictionary:
	var length: float = float(p_plan.length)
	var query := PhysicsRayQueryParameters2D.create(
		p_from, p_from + p_heading * length, int(p_plan.mask), p_exclude)
	query.collide_with_areas = p_areas
	var hit: Dictionary = p_space.intersect_ray(query)
	var row: Dictionary = {"angle": snappedf(p_angle, 0.001), "distance": snappedf(length, 0.001)}
	if hit.is_empty():
		return row
	row.distance = snappedf(p_from.distance_to(hit.position), 0.001)
	row.collider = _path_of(hit.get("collider", null))
	if p_detail:
		row.point = Value.simplify(hit.position)
		row.normal = Value.simplify(hit.normal)
	return row


# One body-width heading: sweep the capsule forward and keep how far it got.
static func _sweep_3d(p_space: PhysicsDirectSpaceState3D,
		p_params: PhysicsShapeQueryParameters3D, p_center: Vector3, p_heading: Vector3,
		p_angle: float, p_plan: Dictionary, p_detail: bool) -> Dictionary:
	var length: float = float(p_plan.length)
	var row: Dictionary = {"angle": snappedf(p_angle, 0.001), "distance": snappedf(length, 0.001)}
	p_params.transform = Transform3D(Basis(), p_center)
	p_params.motion = p_heading * length
	var motion: PackedFloat32Array = p_space.cast_motion(p_params)
	if motion.size() < 2:
		return row
	var safe: float = clampf(motion[0], 0.0, 1.0)
	row.distance = snappedf(safe * length, 0.001)
	if safe >= 1.0:
		return row
	# cast_motion reports fractions only: place the shape just past the safe one and ask what it
	# now overlaps. A miss (thin geometry) is left as a plain distance without a collider.
	p_params.transform = Transform3D(Basis(), p_center + p_heading * (safe * length + PROBE_MARGIN))
	var hits: Array[Dictionary] = p_space.intersect_shape(p_params, 1)
	for hit: Dictionary in hits:
		row.collider = _path_of(hit.get("collider", null))
		break
	if p_detail:
		var rest: Dictionary = p_space.get_rest_info(p_params)
		if not rest.is_empty():
			row.point = Value.simplify(rest.get("point", null))
			row.normal = Value.simplify(rest.get("normal", null))
	return row


static func _sweep_2d(p_space: PhysicsDirectSpaceState2D,
		p_params: PhysicsShapeQueryParameters2D, p_center: Vector2, p_heading: Vector2,
		p_angle: float, p_plan: Dictionary, p_detail: bool) -> Dictionary:
	var length: float = float(p_plan.length)
	var row: Dictionary = {"angle": snappedf(p_angle, 0.001), "distance": snappedf(length, 0.001)}
	p_params.transform = Transform2D(0.0, p_center)
	p_params.motion = p_heading * length
	var motion: PackedFloat32Array = p_space.cast_motion(p_params)
	if motion.size() < 2:
		return row
	var safe: float = clampf(motion[0], 0.0, 1.0)
	row.distance = snappedf(safe * length, 0.001)
	if safe >= 1.0:
		return row
	p_params.transform = Transform2D(0.0, p_center + p_heading * (safe * length + PROBE_MARGIN_2D))
	var hits: Array[Dictionary] = p_space.intersect_shape(p_params, 1)
	for hit: Dictionary in hits:
		row.collider = _path_of(hit.get("collider", null))
		break
	if p_detail:
		var rest: Dictionary = p_space.get_rest_info(p_params)
		if not rest.is_empty():
			row.point = Value.simplify(rest.get("point", null))
			row.normal = Value.simplify(rest.get("normal", null))
	return row


# Turns the per-heading rows into the decision fields. A heading is "open" when the body can move
# at least "need" along it (default: the whole scan length).
static func _summarize(p_out: Dictionary, p_rows: Array[Dictionary], p_plan: Dictionary,
		p_info: Dictionary) -> void:
	var step: float = float(p_plan.step)
	var need: float = float(p_plan.need)
	var length: float = float(p_plan.length)
	var spans: Array = []
	var counts: Array[int] = []
	var open_count: int = 0
	var index: int = 0
	while index < p_rows.size():
		if not _is_open(p_rows[index], need):
			index += 1
			continue
		var start: int = index
		while index + 1 < p_rows.size() and _is_open(p_rows[index + 1], need):
			index += 1
		spans.append([snappedf(float(p_rows[start].angle) - step / 2.0, 0.001),
			snappedf(float(p_rows[index].angle) + step / 2.0, 0.001)])
		counts.append(index - start + 1)
		open_count += index - start + 1
		index += 1
	p_out.passable = not spans.is_empty()
	p_out.open_spans = spans
	p_out.blocked_span = snappedf(float(p_rows.size() - open_count) * step, 0.001)
	p_out.forward = _forward(p_rows, length)
	p_out.hits = _hits(p_rows, length)
	var nearest: Dictionary = _nearest(p_rows, length)
	if not nearest.is_empty():
		p_out.nearest = nearest
	if spans.is_empty():
		# Nowhere to go: still report the least-bad heading, so the caller can see whether "blocked"
		# means a wall ahead or a body already jammed against something.
		p_out.widest = {}
		p_out.steer = _steer(p_rows, _furthest_index(p_rows), p_info, need)
		return
	var widest: int = 0
	for candidate: int in counts.size():
		if counts[candidate] > counts[widest]:
			widest = candidate
	var widest_from: float = float(spans[widest][0])
	var widest_to: float = float(spans[widest][1])
	var mid: float = (widest_from + widest_to) / 2.0
	p_out.widest = {
		"from": widest_from,
		"to": widest_to,
		"span": snappedf(widest_to - widest_from, 0.001),
		"mid": snappedf(mid, 0.001),
		"rays": int(counts[widest]),
	}
	p_out.steer = _steer(p_rows, _closest_index(p_rows, mid), p_info, need)


# One steering suggestion: the heading, its clearance, whether the body fits there, and where that
# lands in world space. The waypoint is what a caller drives to before scanning again.
static func _steer(p_rows: Array[Dictionary], p_index: int, p_info: Dictionary,
		p_need: float) -> Dictionary:
	var row: Dictionary = p_rows[p_index]
	var angle: float = float(row.angle)
	var distance: float = float(row.distance)
	var turn: Dictionary = _turn(p_info, angle, distance)
	return {
		"angle": row.angle,
		"distance": row.distance,
		"open": distance >= p_need - EPSILON,
		"direction": turn.direction,
		"waypoint": turn.waypoint,
	}


static func _turn(p_info: Dictionary, p_angle: float, p_distance: float) -> Dictionary:
	if int(p_info.dim) == 3:
		var base: Vector3 = p_info.base
		var up: Vector3 = p_info.up
		var point: Vector3 = p_info.point
		var heading: Vector3 = base.rotated(up, -deg_to_rad(p_angle)).normalized()
		return {"direction": Value.simplify(heading),
			"waypoint": Value.simplify(point + heading * p_distance)}
	var base2: Vector2 = p_info.base
	var point2: Vector2 = p_info.point
	var heading2: Vector2 = base2.rotated(deg_to_rad(p_angle)).normalized()
	return {"direction": Value.simplify(heading2),
		"waypoint": Value.simplify(point2 + heading2 * p_distance)}


static func _forward(p_rows: Array[Dictionary], p_length: float) -> Dictionary:
	var row: Dictionary = p_rows[_closest_index(p_rows, 0.0)]
	var out: Dictionary = {"angle": row.angle, "distance": row.distance,
		"clear": float(row.distance) >= p_length - EPSILON}
	if row.has("collider"):
		out.collider = row.collider
	return out


# Only headings that actually hit something: the rest are the open spans.
static func _hits(p_rows: Array[Dictionary], p_length: float) -> Array:
	var out: Array = []
	for row: Dictionary in p_rows:
		if not _is_blocked(row, p_length):
			continue
		var hit: Dictionary = {"angle": row.angle, "distance": row.distance}
		if row.has("collider"):
			hit.collider = row.collider
		out.append(hit)
	return out


static func _nearest(p_rows: Array[Dictionary], p_length: float) -> Dictionary:
	var best: Dictionary = {}
	for row: Dictionary in p_rows:
		if not _is_blocked(row, p_length):
			continue
		if best.is_empty() or float(row.distance) < float(best.distance):
			best = {"angle": row.angle, "distance": row.distance}
			if row.has("collider"):
				best.collider = row.collider
	return best


static func _is_open(p_row: Dictionary, p_need: float) -> bool:
	return float(p_row.distance) >= p_need - EPSILON


static func _is_blocked(p_row: Dictionary, p_length: float) -> bool:
	return float(p_row.distance) < p_length - EPSILON


static func _closest_index(p_rows: Array[Dictionary], p_angle: float) -> int:
	var best: int = 0
	for index: int in p_rows.size():
		if absf(float(p_rows[index].angle) - p_angle) < absf(float(p_rows[best].angle) - p_angle):
			best = index
	return best


static func _furthest_index(p_rows: Array[Dictionary]) -> int:
	var best: int = 0
	for index: int in p_rows.size():
		if float(p_rows[index].distance) > float(p_rows[best].distance):
			best = index
	return best


# --- Shared helpers ---

# Bodies the body shape already overlaps: cast_motion skips those, so they would otherwise read as
# clear space. Only meaningful with a body — a thin ray has nothing to overlap.
static func _stuck_3d(p_space: PhysicsDirectSpaceState3D, p_point: Vector3, p_up: Vector3,
		p_exclude: Array[RID], p_request: Dictionary, p_plan: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var radius: float = float(p_plan.radius)
	if radius <= 0.0:
		return out
	var height: float = maxf(float(p_plan.height), radius * 2.0)
	var capsule := CapsuleShape3D.new()
	capsule.radius = maxf(radius - TOUCH_SHRINK, 0.01)
	capsule.height = maxf(height - TOUCH_SHRINK * 2.0, capsule.radius * 2.0)
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = capsule
	params.transform = Transform3D(Basis(), p_point + p_up * (height / 2.0 + TOUCH_LIFT))
	params.collision_mask = int(p_plan.mask)
	params.collide_with_bodies = true
	params.collide_with_areas = bool(p_request.get("areas", false))
	params.exclude = p_exclude
	for hit: Dictionary in p_space.intersect_shape(params, MAX_STUCK):
		var path: String = _path_of(hit.get("collider", null))
		if not out.has(path):
			out.append(path)
	return out


static func _stuck_2d(p_space: PhysicsDirectSpaceState2D, p_point: Vector2,
		p_exclude: Array[RID], p_request: Dictionary, p_plan: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var radius: float = float(p_plan.radius)
	if radius <= 0.0:
		return out
	var circle := CircleShape2D.new()
	circle.radius = maxf(radius - TOUCH_SHRINK_2D, 0.01)
	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = circle
	params.transform = Transform2D(0.0, p_point)
	params.collision_mask = int(p_plan.mask)
	params.collide_with_bodies = true
	params.collide_with_areas = bool(p_request.get("areas", false))
	params.exclude = p_exclude
	for hit: Dictionary in p_space.intersect_shape(params, MAX_STUCK):
		var path: String = _path_of(hit.get("collider", null))
		if not out.has(path):
			out.append(path)
	return out


static func _space_3d(p_context) -> PhysicsDirectSpaceState3D:
	var world: World3D = p_context.viewport().find_world_3d()
	return world.direct_space_state if world != null else null


static func _space_2d(p_context) -> PhysicsDirectSpaceState2D:
	var world: World2D = p_context.viewport().find_world_2d()
	return world.direct_space_state if world != null else null


# The body the scan starts from must not block it: exclude the origin node by default, and accept
# extra "exclude" node paths.
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


# A missing heading means "where the origin node is looking": -Z in 3D, +X in 2D.
static func _direction_3d(p_origin: Dictionary, p_request: Dictionary) -> Vector3:
	if p_request.has("direction"):
		var named: Vector3 = _vec3(p_request.direction)
		if not named.is_zero_approx():
			return named
	var node: Variant = p_origin.get("node", null)
	if node is Node3D:
		return -(node as Node3D).global_transform.basis.z
	return Vector3(0.0, 0.0, -1.0)


static func _direction_2d(p_origin: Dictionary, p_request: Dictionary) -> Vector2:
	if p_request.has("direction"):
		var named: Vector2 = _vec2(p_request.direction)
		if not named.is_zero_approx():
			return named
	var node: Variant = p_origin.get("node", null)
	if node is Node2D:
		return (node as Node2D).global_transform.x
	return Vector2(1.0, 0.0)


# The scan plane's normal (3D only): up defaults to world up, which is what a character on a road
# wants — no need to name it for the common case.
static func _axis(p_value: Variant) -> Vector3:
	var up: Vector3 = _vec3(p_value)
	return Vector3.UP if up.is_zero_approx() else up.normalized()


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
