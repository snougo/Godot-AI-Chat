extends RefCounted

# Turns arbitrary game values into something the protocol can carry: numbers rounded to the shared
# precision, vectors as plain arrays, objects as their path. Used by the "props" observer, so a
# property read straight off a game node survives JSON.

# --- Constants ---

const PRECISION: float = 0.001
# Containers are followed this far and then reduced to a summary string: a Dictionary or Array that
# contains itself (legal in GDScript) would otherwise recurse until the stack is gone, and a probe
# that dies in the middle of a frame has no way left to report anything.
const MAX_DEPTH: int = 8

# --- Public Functions ---

static func simplify(p_value: Variant) -> Variant:
	return _simplify(p_value, 0)

# --- Private Functions ---

static func _simplify(p_value: Variant, p_depth: int) -> Variant:
	match typeof(p_value):
		TYPE_NIL:
			return null
		TYPE_BOOL, TYPE_INT:
			return p_value
		TYPE_FLOAT:
			return snappedf(p_value, PRECISION)
		TYPE_STRING:
			return p_value
		TYPE_STRING_NAME:
			return str(p_value)
		TYPE_VECTOR2:
			var v2: Vector2 = p_value
			return [snappedf(v2.x, PRECISION), snappedf(v2.y, PRECISION)]
		TYPE_VECTOR2I:
			var v2i: Vector2i = p_value
			return [v2i.x, v2i.y]
		TYPE_VECTOR3:
			var v3: Vector3 = p_value
			return [snappedf(v3.x, PRECISION), snappedf(v3.y, PRECISION), snappedf(v3.z, PRECISION)]
		TYPE_VECTOR3I:
			var v3i: Vector3i = p_value
			return [v3i.x, v3i.y, v3i.z]
		TYPE_COLOR:
			var c: Color = p_value
			return [snappedf(c.r, PRECISION), snappedf(c.g, PRECISION),
				snappedf(c.b, PRECISION), snappedf(c.a, PRECISION)]
		TYPE_ARRAY:
			if p_depth >= MAX_DEPTH:
				return "[%d items, depth limit]" % (p_value as Array).size()
			var items: Array = []
			for item: Variant in (p_value as Array):
				items.append(_simplify(item, p_depth + 1))
			return items
		TYPE_DICTIONARY:
			if p_depth >= MAX_DEPTH:
				return "{%d keys, depth limit}" % (p_value as Dictionary).size()
			var dict: Dictionary = {}
			for key: Variant in (p_value as Dictionary):
				dict[str(key)] = _simplify((p_value as Dictionary)[key], p_depth + 1)
			return dict
		TYPE_OBJECT:
			if p_value == null:
				return null
			var obj: Object = p_value
			if obj is Node:
				return str((obj as Node).get_path())
			return "%s#%d" % [obj.get_class(), obj.get_instance_id()]
	return str(p_value)
