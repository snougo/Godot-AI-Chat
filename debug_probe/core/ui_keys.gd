extends RefCounted

# UI naming and visibility, shared by the "ui" observer and the "click" input so both agree on
# what a control is called and whether it counts as on screen.

# "<Owner>.<Name>", where Owner is the nearest CanvasLayer, the scene root, or the node just
# below the scene root: keys stay stable across frames, unlike raw node paths, and two screens
# holding a control of the same name do not collide ("MainMenu.Title" vs "Settings.Title").
static func key_of(p_control: Control, p_scene: Node) -> String:
	var owner_name: String = "Screen"
	var node: Node = p_control.get_parent()
	while node != null:
		if node is CanvasLayer or node == p_scene or node.get_parent() == p_scene:
			owner_name = str(node.name)
			break
		node = node.get_parent()
	return "%s.%s" % [owner_name, p_control.name]


# A control counts as on screen when it is visible in the tree and no ancestor fades it out.
static func is_shown(p_control: Control) -> bool:
	if not p_control.is_visible_in_tree():
		return false
	var alpha: float = 1.0
	var node: Node = p_control
	while node is CanvasItem:
		var item: CanvasItem = node
		alpha *= item.modulate.a * item.self_modulate.a
		node = node.get_parent()
	return alpha > 0.01


# The text a control shows, truncated: enough for an assertion, not a whole document.
static func text_of(p_control: Control) -> String:
	if p_control is RichTextLabel:
		return str(p_control.get_parsed_text()).substr(0, 200)
	if p_control is Label or p_control is Button or p_control is LineEdit or p_control is TextEdit:
		return str(p_control.text).substr(0, 200)
	return ""


# Whether a control takes user input (and therefore belongs in the elements list).
static func is_interactive(p_control: Control) -> bool:
	return p_control is BaseButton or p_control is Range or p_control is LineEdit or p_control is TextEdit


# The first control on screen whose key matches.
static func find_by_key(p_key: String, p_scene: Node) -> Control:
	if p_scene == null:
		return null
	for node: Node in p_scene.find_children("*", "Control", true, false):
		var control: Control = node
		if key_of(control, p_scene) == p_key and is_shown(control):
			return control
	return null
