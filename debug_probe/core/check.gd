extends RefCounted

# Declarative assertions for the "check" plan key:
#   {"sample": "ui", "path": "texts/Settings.Summary", "op": "==", "value": "NAME=Arthur ..."}
#   {"sample": "props", "path": ["/root/UIMenu", "settings", "volume"], "op": ">=", "value": 80}
#
# Evaluated by the step runner at the end of every frame, at the same moment (and under the same
# frame offset) as a sample would be taken. The run returns pass/fail per check instead of raw
# data, so a long sequence stays cheap: N checks per frame cost N booleans, not N JSON blobs.

# --- Constants ---

const SamplePath := preload("res://debug_probe/core/sample_path.gd")
const Value := preload("res://debug_probe/core/value.gd")

const EPSILON: float = 0.001
const OPS: Array[String] = ["==", "!=", "<", "<=", ">", ">=", "has", "missing", "contains"]

# --- Public Functions ---

# Runs every check scheduled for the end of frame p_offset.
static func run(p_checks: Array, p_context, p_offset: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw: Variant in p_checks:
		if typeof(raw) != TYPE_DICTIONARY:
			out.append({"kind": "check", "at": p_offset, "pass": false,
				"error": "a check must be an object"})
			continue
		out.append(_one(raw, p_context, p_offset))
	return out

# --- Private Functions ---

static func _one(p_check: Dictionary, p_context, p_offset: int) -> Dictionary:
	var sample: String = str(p_check.get("sample", "props"))
	var result: Dictionary = {"kind": "check", "at": p_offset, "sample": sample, "pass": false}
	if p_check.has("path"):
		result.path = p_check.path
	var op: String = str(p_check.get("op", "=="))
	if not OPS.has(op):
		result.error = "unknown op '%s' (supported: %s)" % [op, ", ".join(OPS)]
		return result
	if op != "has" and op != "missing" and not p_check.has("value"):
		result.error = "op '%s' needs a 'value'" % op
		return result
	var supported: Array[String] = p_context.observe_keys()
	if not supported.has(sample):
		result.error = "unknown sample '%s' (supported: %s)" % [sample, ", ".join(supported)]
		return result

	var data: Dictionary = p_context.collect([sample])
	var resolved: Dictionary = SamplePath.resolve(data.get(sample), p_check.get("path", ""))
	var found: bool = bool(resolved.get("found", false))
	var actual: Variant = Value.simplify(resolved.get("value"))
	result.found = found
	result.actual = actual
	if op == "has":
		result.pass = found
		return result
	if op == "missing":
		result.pass = not found
		return result
	if not found:
		result.error = "path not found"
		return result
	var expected: Variant = Value.simplify(p_check.get("value"))
	result.expected = expected
	result.pass = _compare(actual, op, expected)
	return result


static func _compare(p_actual: Variant, p_op: String, p_expected: Variant) -> bool:
	if p_op == "contains":
		if p_actual is Array:
			return (p_actual as Array).has(p_expected)
		return str(p_actual).contains(str(p_expected))
	var is_numeric: bool = (p_actual is int or p_actual is float) \
			and (p_expected is int or p_expected is float)
	match p_op:
		"==":
			return _equal_deep(p_actual, p_expected)
		"!=":
			return not _equal_deep(p_actual, p_expected)
		"<", "<=", ">", ">=":
			if not is_numeric:
				return false
			var a: float = float(p_actual)
			var b: float = float(p_expected)
			match p_op:
				"<":
					return a < b
				"<=":
					return a <= b
				">":
					return a > b
				_:
					return a >= b
	return false


# Equality that survives the protocol's own round trip: a request's numbers come back from JSON as
# floats while an observation may hold ints, so [40,344,140,40] has to equal [40.0,344.0,...].
# Plain "==" on arrays says no — correct for GDScript, useless for an assertion.
static func _equal_deep(p_actual: Variant, p_expected: Variant) -> bool:
	if p_actual is Array and p_expected is Array:
		var left: Array = p_actual
		var right: Array = p_expected
		if left.size() != right.size():
			return false
		for i: int in left.size():
			if not _equal_deep(left[i], right[i]):
				return false
		return true
	if p_actual is Dictionary and p_expected is Dictionary:
		var left_dict: Dictionary = p_actual
		var right_dict: Dictionary = p_expected
		if left_dict.size() != right_dict.size():
			return false
		for key: Variant in left_dict:
			if not right_dict.has(key) or not _equal_deep(left_dict[key], right_dict[key]):
				return false
		return true
	var is_numeric: bool = (p_actual is int or p_actual is float) \
			and (p_expected is int or p_expected is float)
	if is_numeric:
		return absf(float(p_actual) - float(p_expected)) <= EPSILON
	if typeof(p_actual) != typeof(p_expected):
		return false
	return p_actual == p_expected
