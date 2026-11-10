extends RefCounted

# Walks a path into a sample: "texts/Settings.Summary", "elements/0/value", or an explicit segment
# array when a key itself contains a slash (props keys are node paths, so use the array form
# there: ["/root/Game/Player", "hp"]).
#
# "Nope" instead of an exception is the point: a typo in an assertion has to come back as
# found = false, which the caller reports, not as a crash that wedges the frame loop.

# --- Public Functions ---

# {"found": bool, "value": Variant}
static func resolve(p_data: Variant, p_path: Variant) -> Dictionary:
	var segments: Array = segments_of(p_path)
	if segments.is_empty():
		return {"found": p_data != null, "value": p_data}
	return walk(p_data, segments)


static func segments_of(p_path: Variant) -> Array:
	if typeof(p_path) == TYPE_ARRAY:
		var out: Array = []
		for raw: Variant in (p_path as Array):
			out.append(str(raw))
		return out
	if typeof(p_path) == TYPE_NIL:
		return []
	return str(p_path).split("/", false)


static func walk(p_data: Variant, p_segments: Array) -> Dictionary:
	var current: Variant = p_data
	for raw: Variant in p_segments:
		var step: Dictionary = _step(current, str(raw))
		if not bool(step.get("found", false)):
			return {"found": false, "value": null}
		current = step.value
	return {"found": true, "value": current}

# --- Private Functions ---

# One segment: a dictionary key, an array index, a vector component, or an object property.
static func _step(p_current: Variant, p_segment: String) -> Dictionary:
	if p_current is Dictionary:
		var dict: Dictionary = p_current
		if dict.has(p_segment):
			return {"found": true, "value": dict[p_segment]}
		return {"found": false, "value": null}
	if p_current is Array:
		if not p_segment.is_valid_int():
			return {"found": false, "value": null}
		var items: Array = p_current
		var index: int = int(p_segment)
		if index < 0 or index >= items.size():
			return {"found": false, "value": null}
		return {"found": true, "value": items[index]}
	if p_current is Vector2 and (p_segment == "x" or p_segment == "y"):
		var v2: Vector2 = p_current
		return {"found": true, "value": v2.x if p_segment == "x" else v2.y}
	if p_current is Vector3 and (p_segment == "x" or p_segment == "y" or p_segment == "z"):
		var v3: Vector3 = p_current
		if p_segment == "x":
			return {"found": true, "value": v3.x}
		return {"found": true, "value": v3.y if p_segment == "y" else v3.z}
	if p_current is Object:
		# A property can hold an Object (a Resource with stats, another node): walk it by name the
		# same way observe_props reads a property, so "stats.kills" works wherever it appears.
		# The name is looked up first on purpose: get() on a missing name would error and stop the
		# frame loop this walk runs in.
		if not is_instance_valid(p_current):
			return {"found": false, "value": null}
		var object: Object = p_current
		for entry: Dictionary in object.get_property_list():
			if str(entry.get("name", "")) == p_segment:
				return {"found": true, "value": object.get(p_segment)}
		return {"found": false, "value": null}
	return {"found": false, "value": null}
