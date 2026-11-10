extends RefCounted

# Plan inputs "press" and "release": an InputMap action first, otherwise a Godot key name as a
# real key event.
#
# Holds are tracked so cleanup() can never leave a key stuck down after a disconnect, a scene
# change or the node leaving the tree.
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Private Vars ---

var _pressed_actions: Array[String] = []
var _held_keys: Array[int] = []

# --- Public Functions ---

func keys() -> Array[String]:
	return ["press", "release"]


# Returns null: a press has no side result to report.
func apply(p_kind: String, p_payload: Variant, _p_context, _p_index: int) -> Variant:
	if typeof(p_payload) != TYPE_ARRAY:
		return null
	for raw: Variant in p_payload:
		_set_hold(str(raw), p_kind == "press")
	return null


func cleanup() -> void:
	for action: String in _pressed_actions:
		Input.action_release(action)
	_pressed_actions.clear()
	for code: int in _held_keys:
		var ev := InputEventKey.new()
		ev.keycode = code as Key
		ev.physical_keycode = code as Key
		ev.pressed = false
		Input.parse_input_event(ev)
	_held_keys.clear()
	Input.flush_buffered_events()


# Re-asserts a hold that something outside the probe dropped: a window focus change releases the
# virtual action state (and the physical key state with it), and a step that keeps running would
# then look like "the player just stopped" with no error anywhere. Only re-pressed when actually
# released, so is_action_just_pressed() does not fire again every frame.
func keep() -> void:
	for action: String in _pressed_actions:
		if not Input.is_action_pressed(action):
			Input.action_press(action, 1.0)
	# A real key is dropped by the same focus change, and the rule above applies to it too: send the
	# press again only while the key reads as up.
	for code: int in _held_keys:
		if Input.is_key_pressed(code as Key):
			continue
		var ev := InputEventKey.new()
		ev.keycode = code as Key
		ev.physical_keycode = code as Key
		ev.pressed = true
		Input.parse_input_event(ev)

# --- Private Functions ---

func _set_hold(p_name: String, p_pressed: bool) -> void:
	if p_name.is_empty():
		return
	if InputMap.has_action(p_name):
		if p_pressed:
			Input.action_press(p_name, 1.0)
			if not _pressed_actions.has(p_name):
				_pressed_actions.append(p_name)
		else:
			Input.action_release(p_name)
			_pressed_actions.erase(p_name)
		return
	var code: int = OS.find_keycode_from_string(p_name)
	if code == KEY_NONE:
		push_warning("[AiDebugProbe] unknown input: %s" % p_name)
		return
	var ev := InputEventKey.new()
	ev.keycode = code as Key
	ev.physical_keycode = code as Key
	ev.pressed = p_pressed
	Input.parse_input_event(ev)
	if p_pressed:
		if not _held_keys.has(code):
			_held_keys.append(code)
	else:
		_held_keys.erase(code)
