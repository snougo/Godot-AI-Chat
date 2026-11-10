extends RefCounted

# Plan input "hover": move the mouse over a control, or to a viewport point, without pressing.
#
# A hover is not a click: it is what makes tooltips, hover highlights and "the button lit up"
# states happen — and those are states a click test cannot observe, because the click is over
# before the sample is taken.
#
#   {"at": 3, "hover": ["UIMenu.PlayButton"]}
#   {"at": 3, "hover": {"point": [300, 200]}}
#   {"at": 3, "hover": [300, 200]}
#
# The reply says which control the viewport actually considers hovered, so "the tooltip did not
# appear" can be traced to "the mouse was not over the control" instead of guessed.
#
# Capability contract (duck typed, no base class): keys() / apply(). A hover holds nothing, so it
# implements neither keep() nor cleanup(); the context calls both only when they exist.

# --- Constants ---

const UiKeys := preload("res://debug_probe/core/ui_keys.gd")
const UiInput := preload("res://debug_probe/core/ui_input.gd")

# --- Public Functions ---

func keys() -> Array[String]:
	return ["hover"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	var target: Dictionary = _target(p_payload, p_context)
	if not bool(target.get("ok", false)):
		return {"kind": "hover", "at": p_index, "matches": false,
			"error": str(target.get("error", "bad hover target"))}

	var point: Vector2 = target.point
	var control: Control = target.get("control", null)
	var was_paused: bool = UiInput.lift_pause(p_context)
	UiInput.push_hover(p_context.viewport(), point)
	var hovered: Control = p_context.viewport().gui_get_hovered_control()
	UiInput.restore_pause(p_context, was_paused)

	var scene: Node = p_context.tree().current_scene
	return {
		"kind": "hover", "at": p_index,
		"key": str(target.get("key", "")),
		"pos": [int(point.x), int(point.y)],
		"over": UiKeys.key_of(hovered, scene) if hovered != null else "",
		"matches": control != null and hovered == control,
		"error": "",
	}

# --- Private Functions ---

func _target(p_payload: Variant, p_context) -> Dictionary:
	if typeof(p_payload) == TYPE_DICTIONARY:
		var entry: Dictionary = p_payload
		if entry.has("point"):
			return _from_point(entry.point)
		if entry.has("key"):
			return _from_key(str(entry.key), p_context)
		return {"ok": false, "error": "hover needs \"key\" or \"point\""}
	if typeof(p_payload) == TYPE_ARRAY:
		var arr: Array = p_payload
		if arr.size() >= 2 and (arr[0] is int or arr[0] is float) \
				and (arr[1] is int or arr[1] is float):
			return _from_point(arr)
		if not arr.is_empty():
			return _from_key(str(arr[0]), p_context)
		return {"ok": false, "error": "empty hover payload"}
	if typeof(p_payload) == TYPE_STRING:
		return _from_key(str(p_payload), p_context)
	return {"ok": false, "error": "hover payload must be a key, a point or an object"}


func _from_key(p_key: String, p_context) -> Dictionary:
	var control: Control = UiKeys.find_by_key(p_key, p_context.tree().current_scene)
	if control == null:
		return {"ok": false, "error": "no such control on screen: %s" % p_key}
	var rect: Rect2 = control.get_global_rect()
	if not rect.has_area():
		return {"ok": false, "error": "control has no area: %s" % p_key}
	return {"ok": true, "key": p_key, "control": control, "point": rect.get_center()}


func _from_point(p_point: Variant) -> Dictionary:
	var arr: Array = p_point if typeof(p_point) == TYPE_ARRAY else []
	if arr.size() < 2:
		return {"ok": false, "error": "point needs two numbers"}
	return {"ok": true, "key": "", "point": Vector2(float(arr[0]), float(arr[1]))}
