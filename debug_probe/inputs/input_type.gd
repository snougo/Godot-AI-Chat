extends RefCounted

# Plan input "type": focus a text control by clicking it, then type the text as real key events.
#
# Deliberately goes through the GUI: a field that is covered, disabled or read-only refuses the
# click, and the reply says so — instead of text appearing in a control the player cannot reach.
#
# Payload: {"key": "UIMenu.NameEdit", "text": "Arthur", "replace": true, "submit": false,
#           "focus": true}
#   replace (default true)  select the existing text first, so typing overwrites it
#   submit  (default false) send Enter afterwards, firing text_submitted
#   focus   (default true)  click the control first to focus it and place the caret. Set it to
#                           false to type into whatever selection is already there (see "select").
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Constants ---

const UiKeys := preload("res://debug_probe/core/ui_keys.gd")
const UiInput := preload("res://debug_probe/core/ui_input.gd")

# --- Public Functions ---

func keys() -> Array[String]:
	return ["type"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	if typeof(p_payload) != TYPE_DICTIONARY:
		return _fail("", p_index, "payload must be {\"key\": ..., \"text\": ...}")
	var key: String = str(p_payload.get("key", ""))
	var text: String = str(p_payload.get("text", ""))
	return _type(key, text, bool(p_payload.get("replace", true)),
			bool(p_payload.get("submit", false)), bool(p_payload.get("focus", true)),
			p_context, p_index)


func cleanup() -> void:
	pass

# --- Private Functions ---

func _type(p_key: String, p_text: String, p_replace: bool, p_submit: bool, p_focus: bool,
		p_context, p_index: int) -> Dictionary:
	var control: Control = UiKeys.find_by_key(p_key, p_context.tree().current_scene)
	if control == null:
		return _fail(p_key, p_index, "no such control on screen")
	if not (control is LineEdit or control is TextEdit):
		return _fail(p_key, p_index, "%s does not take text" % control.get_class())
	var rect: Rect2 = control.get_global_rect()
	if not rect.has_area():
		return _fail(p_key, p_index, "control has no area to click")

	# A real click both focuses the field and places the caret: the right edge means "at the end",
	# which is what appending needs. With focus = false the caret and any selection are left alone,
	# which is the only way to type over a selection made by "select".
	var click_at: Vector2 = rect.get_center()
	if not p_replace:
		click_at = Vector2(rect.end.x - 2.0, rect.position.y + rect.size.y * 0.5)

	var was_paused: bool = UiInput.lift_pause(p_context)
	if p_focus:
		UiInput.push_mouse(p_context.viewport(), click_at, true)
		UiInput.push_mouse(p_context.viewport(), click_at, false)
	var focused: bool = control.has_focus()
	if focused:
		if p_replace and p_focus:
			UiInput.select_all(p_context.viewport())
		UiInput.push_text(p_context.viewport(), p_text)
		if p_submit:
			UiInput.push_key(p_context.viewport(), KEY_ENTER, 0, true)
			UiInput.push_key(p_context.viewport(), KEY_ENTER, 0, false)
	UiInput.restore_pause(p_context, was_paused)

	var typed: String = str(control.text).substr(0, 200)
	return {
		"kind": "type", "at": p_index, "key": p_key,
		"typed": p_text, "focused": focused, "text": typed,
		"error": "" if focused else "the control did not take focus (covered, disabled or read-only)",
	}


func _fail(p_key: String, p_index: int, p_error: String) -> Dictionary:
	return {"kind": "type", "at": p_index, "key": p_key, "focused": false, "error": p_error}
