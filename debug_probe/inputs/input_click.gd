extends RefCounted

# Plan input "click": a mouse move plus a press and release on a control's centre, pushed into
# the viewport so GUI hit-testing (and occlusion) applies exactly as for a real mouse.
#
#   {"at": 9, "click": ["HUD.StartButton"]}
#   {"at": 9, "click": {"key": "HUD.Panel", "button": "right"}}
#   {"at": 9, "click": ["HUD.Ok", {"key": "HUD.Panel", "button": "middle"}]}
#
# Reports whether the control's pressed signal actually fired, so a blocked or disabled control
# reads as a failure instead of a silent no-op. For a button the accepted button mask comes back
# too: a right click on a button that only listens for the left one is not a bug in the probe.
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Constants ---

const UiKeys := preload("res://debug_probe/core/ui_keys.gd")
const UiInput := preload("res://debug_probe/core/ui_input.gd")

# --- Public Functions ---

func keys() -> Array[String]:
	return ["click"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	var entries: Array = []
	if typeof(p_payload) == TYPE_ARRAY:
		entries = p_payload
	elif typeof(p_payload) == TYPE_DICTIONARY:
		entries = [p_payload]
	else:
		return null
	var clicks: Array[Dictionary] = []
	for raw: Variant in entries:
		if typeof(raw) == TYPE_DICTIONARY:
			var entry: Dictionary = raw
			clicks.append(_click(str(entry.get("key", "")),
				_button_of(str(entry.get("button", "left"))), p_context, p_index))
		else:
			clicks.append(_click(str(raw), MOUSE_BUTTON_LEFT, p_context, p_index))
	if clicks.is_empty():
		return null
	if clicks.size() == 1:
		return clicks[0]
	return {"kind": "click", "at": p_index, "clicks": clicks}


func cleanup() -> void:
	pass

# --- Private Functions ---

func _click(p_key: String, p_button: MouseButton, p_context, p_index: int) -> Dictionary:
	var scene: Node = p_context.tree().current_scene
	var control: Control = UiKeys.find_by_key(p_key, scene)
	if control == null:
		return {"kind": "click", "at": p_index, "key": p_key, "fired": false,
			"error": "no such control on screen"}

	var pos: Vector2 = control.get_global_rect().get_center()
	var state: Dictionary = {"fired": false}
	var on_pressed := func() -> void: state.fired = true
	var is_button: bool = control is BaseButton
	if is_button:
		control.pressed.connect(on_pressed)

	# GUI input is dropped while the tree is paused: let it through for the duration of the click.
	# Keyboard input does not need this (Input.* is global state).
	var was_paused: bool = UiInput.lift_pause(p_context)
	UiInput.push_mouse(p_context.viewport(), pos, true, p_button)
	UiInput.push_mouse(p_context.viewport(), pos, false, p_button)
	UiInput.restore_pause(p_context, was_paused)

	if is_button and control.pressed.is_connected(on_pressed):
		control.pressed.disconnect(on_pressed)
	var out: Dictionary = {"kind": "click", "at": p_index, "key": p_key,
		"pos": [int(pos.x), int(pos.y)], "button": _button_name(p_button), "fired": state.fired}
	if control is BaseButton:
		out.mask = (control as BaseButton).button_mask
	return out

# --- Button helpers ---

func _button_of(p_name: String) -> MouseButton:
	match p_name:
		"right":
			return MOUSE_BUTTON_RIGHT
		"middle":
			return MOUSE_BUTTON_MIDDLE
		_:
			return MOUSE_BUTTON_LEFT


func _button_name(p_button: MouseButton) -> String:
	match p_button:
		MOUSE_BUTTON_RIGHT:
			return "right"
		MOUSE_BUTTON_MIDDLE:
			return "middle"
		_:
			return "left"
