extends RefCounted

# Input plumbing shared by the UI plan keys (click / type / drag): the one place that knows how a
# mouse or a key event goes into the viewport, and that GUI input is dropped while the tree is
# paused.

# --- Public Functions ---

# GUI input is dropped while the tree is paused, so a UI interaction runs with the pause lifted.
# Returns the previous state, to be handed back to restore_pause().
static func lift_pause(p_context) -> bool:
	var tree: SceneTree = p_context.tree()
	var was_paused: bool = tree.paused
	tree.paused = false
	return was_paused


static func restore_pause(p_context, p_was_paused: bool) -> void:
	p_context.tree().paused = p_was_paused


# A mouse move plus a press or release at a viewport position, so GUI hit-testing (and occlusion)
# applies exactly as for a real mouse. The button matters: a right click is a different decision for
# the control than a left one.
#
# The move that comes first matches the button as well: a plain hover before a press, and a move
# with THAT button held before a release. A left-held motion in front of a right click would hand
# the control a drag it never started.
static func push_mouse(p_viewport: Viewport, p_position: Vector2, p_pressed: bool,
		p_button: MouseButton = MOUSE_BUTTON_LEFT) -> void:
	if p_pressed:
		push_hover(p_viewport, p_position)
	else:
		push_button_motion(p_viewport, p_position, p_button)
	var button := InputEventMouseButton.new()
	button.button_index = p_button
	button.pressed = p_pressed
	button.position = p_position
	button.global_position = p_position
	p_viewport.push_input(button, true)


# A bare mouse move with no button held: what a hover looks like.
static func push_hover(p_viewport: Viewport, p_position: Vector2) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = p_position
	motion.global_position = p_position
	motion.button_mask = 0
	p_viewport.push_input(motion, true)


# A move with the left button held: what a drag looks like between press and release.
static func push_drag_motion(p_viewport: Viewport, p_position: Vector2) -> void:
	push_button_motion(p_viewport, p_position, MOUSE_BUTTON_LEFT)


# A move with p_button held: the drag half of a click that is not a left click.
static func push_button_motion(p_viewport: Viewport, p_position: Vector2,
		p_button: MouseButton) -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = p_position
	motion.global_position = p_position
	match p_button:
		MOUSE_BUTTON_RIGHT:
			motion.button_mask = MOUSE_BUTTON_MASK_RIGHT
		MOUSE_BUTTON_MIDDLE:
			motion.button_mask = MOUSE_BUTTON_MASK_MIDDLE
		_:
			motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	p_viewport.push_input(motion, true)


# One key event. unicode != 0 makes it a text key, which is what a LineEdit inserts.
# p_autoremap uses the platform's primary modifier (Ctrl on Windows/Linux, Cmd on macOS)
# instead of Ctrl specifically — Ctrl+A selects nothing on macOS.
static func push_key(p_viewport: Viewport, p_keycode: int, p_unicode: int, p_pressed: bool, p_ctrl: bool = false, p_autoremap: bool = false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = p_keycode as Key
	ev.physical_keycode = p_keycode as Key
	ev.unicode = p_unicode
	ev.pressed = p_pressed
	ev.ctrl_pressed = p_ctrl
	ev.command_or_control_autoremap = p_autoremap
	p_viewport.push_input(ev, true)


# Types a string one key at a time, so max_length, filters and text_changed all run for real.
static func push_text(p_viewport: Viewport, p_text: String) -> void:
	for i: int in p_text.length():
		var c: String = p_text[i]
		var unicode: int = c.unicode_at(0)
		var code: int = keycode_of(c)
		push_key(p_viewport, code, unicode, true)
		push_key(p_viewport, code, unicode, false)


# Selects the whole text of the focused control (Ctrl+A, or Cmd+A on macOS), the way a user
# replacing a field does. Goes through the platform's primary modifier so it works everywhere.
static func select_all(p_viewport: Viewport) -> void:
	push_key(p_viewport, KEY_A, 0, true, false, true)
	push_key(p_viewport, KEY_A, 0, false, false, true)


# The key for a printable character: letters and digits get their named key, everything else
# relies on unicode alone.
static func keycode_of(p_char: String) -> int:
	var lower: String = p_char.to_lower()
	var code: int = lower.unicode_at(0)
	if code >= 97 and code <= 122:
		return KEY_A + (code - 97)
	if code >= 48 and code <= 57:
		return KEY_0 + (code - 48)
	return KEY_NONE
