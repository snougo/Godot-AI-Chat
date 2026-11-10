extends RefCounted

# Structural diff between two run records ({"samples": ..., "results": ...}): what changed, at
# which path, with both values. Used by the "replay" plan key, where the whole point is that the
# answer is short — "identical" or a handful of paths — instead of two full payloads to eyeball.
#
# Numbers are compared with the protocol's precision, so float noise from a different summation
# order does not read as a change.

# --- Constants ---

const EPSILON: float = 0.001
const MAX_DIFFERENCES: int = 60

# --- Public Functions ---

# {"identical": bool, "count": int, "truncated": bool, "differences": [{path, baseline, current}]}
static func compare(p_baseline: Variant, p_current: Variant) -> Dictionary:
	var out: Array[Dictionary] = []
	_walk(p_baseline, p_current, "", out)
	var truncated: bool = out.size() > MAX_DIFFERENCES
	if truncated:
		out.resize(MAX_DIFFERENCES)
	return {"identical": out.is_empty(), "count": out.size(),
		"truncated": truncated, "differences": out}

# --- Private Functions ---

static func _walk(p_baseline: Variant, p_current: Variant, p_path: String, p_out: Array[Dictionary]) -> void:
	if p_out.size() > MAX_DIFFERENCES:
		return
	if typeof(p_baseline) == TYPE_DICTIONARY and typeof(p_current) == TYPE_DICTIONARY:
		var baseline: Dictionary = p_baseline
		var current: Dictionary = p_current
		for key: Variant in baseline:
			var child: String = "%s/%s" % [p_path, str(key)]
			if not current.has(key):
				_add(p_out, child, baseline[key], null, "missing now")
				continue
			_walk(baseline[key], current[key], child, p_out)
		for key: Variant in current:
			if not baseline.has(key):
				_add(p_out, "%s/%s" % [p_path, str(key)], null, current[key], "new")
		return
	if typeof(p_baseline) == TYPE_ARRAY and typeof(p_current) == TYPE_ARRAY:
		var baseline_items: Array = p_baseline
		var current_items: Array = p_current
		var shared: int = mini(baseline_items.size(), current_items.size())
		for i: int in shared:
			_walk(baseline_items[i], current_items[i], "%s/%d" % [p_path, i], p_out)
		if baseline_items.size() != current_items.size():
			_add(p_out, "%s/size" % p_path, baseline_items.size(), current_items.size(), "size")
		return
	if _same(p_baseline, p_current):
		return
	_add(p_out, p_path, p_baseline, p_current, "changed")


static func _same(p_baseline: Variant, p_current: Variant) -> bool:
	var is_numeric: bool = (p_baseline is int or p_baseline is float) \
			and (p_current is int or p_current is float)
	if is_numeric:
		return absf(float(p_baseline) - float(p_current)) <= EPSILON
	if typeof(p_baseline) != typeof(p_current):
		return false
	return p_baseline == p_current


static func _add(p_out: Array[Dictionary], p_path: String, p_baseline: Variant,
		p_current: Variant, p_kind: String) -> void:
	p_out.append({"path": p_path if not p_path.is_empty() else "(root)",
		"baseline": p_baseline, "current": p_current, "kind": p_kind})
