extends RefCounted

# Watch "ui": visible text and interactive controls — what the player can read and press right
# now.
#
# Keys are "<Owner>.<Name>" (see core/ui_keys.gd); the same keys are what a "click" plan entry
# takes, so an AI can read a control's state and click it without guessing a node path.
#
# Capability contract (duck typed, no base class): key() / collect().

# --- Constants ---

const UiKeys := preload("res://debug_probe/core/ui_keys.gd")

# --- Public Functions ---

func key() -> String:
	return "ui"


func collect(p_context) -> Variant:
	var texts: Dictionary = {}
	var rects: Dictionary = {}
	var elements: Array[Dictionary] = []
	var scene: Node = p_context.tree().current_scene
	if scene == null:
		return {"texts": texts, "rects": rects, "elements": elements}
	for node: Node in scene.find_children("*", "Control", true, false):
		var control: Control = node
		if not UiKeys.is_shown(control):
			continue
		var control_key: String = UiKeys.key_of(control, scene)
		rects[control_key] = _rect(control)
		var text: String = UiKeys.text_of(control)
		if text != "":
			texts[control_key] = text
		if UiKeys.is_interactive(control):
			elements.append(_element(control_key, control))
	return {"texts": texts, "rects": rects, "elements": elements}

# --- Private Functions ---

# Pixel rectangle as [x, y, width, height]: the numbers a layout regression needs, without a
# screenshot. Every shown control gets one; "screen" below is just its centre.
func _rect(p_control: Control) -> Array:
	var rect: Rect2 = p_control.get_global_rect()
	return [int(rect.position.x), int(rect.position.y), int(rect.size.x), int(rect.size.y)]


# The state of an interactive control; screen is the control's centre in viewport pixels.
func _element(p_key: String, p_control: Control) -> Dictionary:
	var rect: Rect2 = p_control.get_global_rect()
	var d: Dictionary = {
		"key": p_key,
		"class": p_control.get_class(),
		"rect": _rect(p_control),
		"screen": [int(rect.position.x + rect.size.x * 0.5), int(rect.position.y + rect.size.y * 0.5)],
	}
	if p_control is OptionButton:
		var option: OptionButton = p_control
		d.enabled = not option.disabled
		d.selected = option.selected
		d.item_text = option.get_item_text(option.selected) if option.selected >= 0 else ""
	elif p_control is BaseButton:
		var button: BaseButton = p_control
		d.enabled = not button.disabled
		d.pressed = button.button_pressed
	elif p_control is Range:
		var range_control: Range = p_control
		d.value = snappedf(range_control.value, 0.001)
		d.max = snappedf(range_control.max_value, 0.001)
	elif p_control is LineEdit:
		var edit: LineEdit = p_control
		d.editable = edit.editable
		d.caret = edit.caret_column
		d.sel = [edit.get_selection_from_column(), edit.get_selection_to_column()] \
				if edit.has_selection() else []
	elif p_control is TextEdit:
		var area: TextEdit = p_control
		d.editable = area.editable
		d.caret = [area.get_caret_line(), area.get_caret_column()]
		d.sel = [[area.get_selection_from_line(), area.get_selection_from_column()],
			[area.get_selection_to_line(), area.get_selection_to_column()]] \
				if area.has_selection() else []
	# Whether the player's input would land here right now: the one thing a text or slider test
	# cannot infer from "it exists on screen".
	d.focused = p_control.has_focus() if p_control.focus_mode != Control.FOCUS_NONE else false
	return d
