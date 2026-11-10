extends RefCounted

# Plan input "set": give a Range control a value, or pick an OptionButton entry.
#
# Goes through the control's own API, so value_changed / item_selected fire and every listener
# runs — but it does NOT test the widget: hit-testing, occlusion and grabbing belong to "click",
# "type" and "drag". It answers "make the game believe volume is 30", not "can the player reach
# the slider".
#
# Payload: {"key": "UIMenu.VolumeSlider", "value": 30}
#          {"key": "UIMenu.QualityOption", "index": 2}
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Constants ---

const UiKeys := preload("res://debug_probe/core/ui_keys.gd")

# --- Public Functions ---

func keys() -> Array[String]:
	return ["set"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	if typeof(p_payload) != TYPE_DICTIONARY:
		return _fail("", p_index, "payload must be {\"key\": ..., \"value\": ...}")
	var key: String = str(p_payload.get("key", ""))
	var control: Control = UiKeys.find_by_key(key, p_context.tree().current_scene)
	if control == null:
		return _fail(key, p_index, "no such control on screen")
	if control is Range:
		if not p_payload.has("value"):
			return _fail(key, p_index, "%s needs \"value\"" % control.get_class())
		return _set_value(key, control, p_payload.value, p_index)
	if control is OptionButton:
		if not p_payload.has("index"):
			return _fail(key, p_index, "%s needs \"index\"" % control.get_class())
		return _select_item(key, control, int(p_payload.index), p_index)
	return _fail(key, p_index, "%s takes neither a value nor an index" % control.get_class())


func cleanup() -> void:
	pass

# --- Private Functions ---

func _set_value(p_key: String, p_control: Range, p_value: float, p_index: int) -> Dictionary:
	var before: float = p_control.value
	p_control.set_value(float(p_value))
	return {
		"kind": "set", "at": p_index, "key": p_key, "target": "value",
		"requested": snappedf(float(p_value), 0.001),
		"before": snappedf(before, 0.001),
		"value": snappedf(p_control.value, 0.001),
		"ratio": snappedf(p_control.ratio, 0.001),
		"error": "",
	}


func _select_item(p_key: String, p_control: OptionButton, p_index_value: int, p_index: int) -> Dictionary:
	if p_index_value < 0 or p_index_value >= p_control.item_count:
		return _fail(p_key, p_index, "index %d is outside 0..%d" % [p_index_value, p_control.item_count - 1])
	var before: int = p_control.selected
	# select() sets the selection without a signal; a real pick from the popup also emits this,
	# so the button's listeners run exactly once.
	p_control.select(p_index_value)
	p_control.item_selected.emit(p_index_value)
	return {
		"kind": "set", "at": p_index, "key": p_key, "target": "index",
		"requested": p_index_value, "before": before,
		"selected": p_control.selected, "text": p_control.get_item_text(p_control.selected),
		"error": "",
	}


func _fail(p_key: String, p_index: int, p_error: String) -> Dictionary:
	return {"kind": "set", "at": p_index, "key": p_key, "error": p_error}
