extends RefCounted

# Plan input "drag": press, move and release a control with the mouse — a slider thumb being
# dragged, which "set" cannot test because it skips the widget.
#
# Payload: {"key": "UIMenu.VolumeSlider", "from": 20, "to": 85, "steps": 6}
#   from / to  a number: a Range value, mapped onto the slider's travel
#              [x, y]:  viewport pixels, for a control that is not a slider
#   steps      intermediate moves between press and release (default 6)
#
# The reply carries the values actually reached, so an assertion never depends on the value to
# pixel mapping being exact.
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Constants ---

const UiKeys := preload("res://debug_probe/core/ui_keys.gd")
const UiInput := preload("res://debug_probe/core/ui_input.gd")

# --- Public Functions ---

func keys() -> Array[String]:
	return ["drag"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	if typeof(p_payload) != TYPE_DICTIONARY:
		return _fail("", p_index, "payload must be {\"key\": ..., \"from\": ..., \"to\": ...}")
	var key: String = str(p_payload.get("key", ""))
	if not p_payload.has("from") or not p_payload.has("to"):
		return _fail(key, p_index, "drag needs \"from\" and \"to\"")
	return _drag(key, p_payload.from, p_payload.to, maxi(1, int(p_payload.get("steps", 6))),
			p_context, p_index)


func cleanup() -> void:
	pass

# --- Private Functions ---

func _drag(p_key: String, p_from: Variant, p_to: Variant, p_steps: int, p_context, p_index: int) -> Dictionary:
	var control: Control = UiKeys.find_by_key(p_key, p_context.tree().current_scene)
	if control == null:
		return _fail(p_key, p_index, "no such control on screen")
	var rect: Rect2 = control.get_global_rect()
	if not rect.has_area():
		return _fail(p_key, p_index, "control has no area to drag")

	var start: Vector2 = _point(control, rect, p_from)
	var finish: Vector2 = _point(control, rect, p_to)
	var before: float = 0.0
	if control is Range:
		before = (control as Range).value

	var was_paused: bool = UiInput.lift_pause(p_context)
	UiInput.push_mouse(p_context.viewport(), start, true)
	for i: int in range(1, p_steps + 1):
		UiInput.push_drag_motion(p_context.viewport(), start.lerp(finish, float(i) / float(p_steps)))
	UiInput.push_mouse(p_context.viewport(), finish, false)
	UiInput.restore_pause(p_context, was_paused)

	var result: Dictionary = {
		"kind": "drag", "at": p_index, "key": p_key,
		"from": [int(start.x), int(start.y)], "to": [int(finish.x), int(finish.y)],
		"steps": p_steps, "error": "",
	}
	if control is Range:
		var range_control: Range = control
		result.before = snappedf(before, 0.001)
		result.value = snappedf(range_control.value, 0.001)
		result.ratio = snappedf(range_control.ratio, 0.001)
	elif control is BaseButton:
		result.pressed = (control as BaseButton).button_pressed
	return result


# Where to put the mouse: pixels go through untouched, a Range value is mapped onto the travel of
# its grabber.
func _point(p_control: Control, p_rect: Rect2, p_target: Variant) -> Vector2:
	if typeof(p_target) == TYPE_ARRAY and (p_target as Array).size() >= 2:
		var px: Array = p_target
		return Vector2(float(px[0]), float(px[1]))
	if p_control is Range:
		var range_control: Range = p_control
		var span: float = range_control.max_value - range_control.min_value
		var ratio: float = 0.0
		if not is_zero_approx(span):
			ratio = clampf((float(p_target) - range_control.min_value) / span, 0.0, 1.0)
		if p_control is VSlider:
			return Vector2(p_rect.get_center().x, p_rect.position.y + p_rect.size.y * (1.0 - ratio))
		return Vector2(p_rect.position.x + p_rect.size.x * ratio, p_rect.get_center().y)
	return p_rect.get_center()


func _fail(p_key: String, p_index: int, p_error: String) -> Dictionary:
	return {"kind": "drag", "at": p_index, "key": p_key, "error": p_error}
