extends RefCounted

# Plan input "select": set the text selection of a LineEdit / TextEdit through the control's own
# API — deterministic, like "set" for a slider. Dragging a selection with the mouse is a different
# (and much flakier) thing; this answers "make the game believe characters 4..9 are selected".
#
#   {"at": 4, "select": {"key": "Settings.Notes", "from": [0, 0], "to": [0, 4]}}   TextEdit: line/col
#   {"at": 4, "select": {"key": "Settings.NameEdit", "from": 0, "to": 4}}           LineEdit: columns
#   {"at": 4, "select": {"key": "Settings.Notes", "all": true}}
#   {"at": 4, "select": {"key": "Settings.Notes", "clear": true}}
#
# Then `type` with {"focus": false, "replace": false} types over the selection: a replacement is a
# different code path in every editor widget than an insert, and only a selection reaches it.
#
# Capability contract (duck typed, no base class): keys() / apply() / cleanup().

# --- Constants ---

const UiKeys := preload("res://debug_probe/core/ui_keys.gd")

# --- Public Functions ---

func keys() -> Array[String]:
	return ["select"]


func apply(_p_kind: String, p_payload: Variant, p_context, p_index: int) -> Variant:
	if typeof(p_payload) != TYPE_DICTIONARY:
		return _fail("", p_index, "payload must be {\"key\": ...}")
	var entry: Dictionary = p_payload
	var key: String = str(entry.get("key", ""))
	var control: Control = UiKeys.find_by_key(key, p_context.tree().current_scene)
	if control == null:
		return _fail(key, p_index, "no such control on screen")
	if control is TextEdit:
		return _text_edit(key, control, entry, p_index)
	if control is LineEdit:
		return _line_edit(key, control, entry, p_index)
	return _fail(key, p_index, "%s has no text selection" % control.get_class())


func cleanup() -> void:
	pass

# --- Private Functions ---

func _text_edit(p_key: String, p_control: TextEdit, p_entry: Dictionary, p_index: int) -> Dictionary:
	if bool(p_entry.get("clear", false)):
		p_control.deselect()
	elif bool(p_entry.get("all", false)):
		p_control.select_all()
	elif p_entry.has("from") and p_entry.has("to"):
		var from: Array = _pair(p_entry.from)
		var to: Array = _pair(p_entry.to)
		if from.is_empty() or to.is_empty():
			return _fail(p_key, p_index, "TextEdit needs from/to as [line, column]")
		p_control.select(int(from[0]), int(from[1]), int(to[0]), int(to[1]))
	else:
		return _fail(p_key, p_index, "select needs \"all\", \"clear\" or \"from\"/\"to\"")
	return _result(p_key, p_control, p_index)


func _line_edit(p_key: String, p_control: LineEdit, p_entry: Dictionary, p_index: int) -> Dictionary:
	if bool(p_entry.get("clear", false)):
		p_control.deselect()
	elif bool(p_entry.get("all", false)):
		p_control.select_all()
	elif p_entry.has("from") and p_entry.has("to"):
		if not _is_number(p_entry.from) or not _is_number(p_entry.to):
			return _fail(p_key, p_index, "LineEdit needs from/to as column numbers")
		p_control.select(int(p_entry.from), int(p_entry.to))
	else:
		return _fail(p_key, p_index, "select needs \"all\", \"clear\" or \"from\"/\"to\"")
	return _result(p_key, p_control, p_index)


func _result(p_key: String, p_control: Control, p_index: int) -> Dictionary:
	var out: Dictionary = {"kind": "select", "at": p_index, "key": p_key,
		"class": p_control.get_class(), "error": ""}
	if p_control is TextEdit:
		var area: TextEdit = p_control
		out.caret = [area.get_caret_line(), area.get_caret_column()]
		if area.has_selection():
			out.sel = [[area.get_selection_from_line(), area.get_selection_from_column()],
				[area.get_selection_to_line(), area.get_selection_to_column()]]
		else:
			out.sel = []
	else:
		var edit: LineEdit = p_control
		out.caret = edit.caret_column
		if edit.has_selection():
			out.sel = [edit.get_selection_from_column(), edit.get_selection_to_column()]
		else:
			out.sel = []
	return out


func _pair(p_value: Variant) -> Array:
	if typeof(p_value) == TYPE_ARRAY and (p_value as Array).size() >= 2:
		return p_value
	return []


func _is_number(p_value: Variant) -> bool:
	return p_value is int or p_value is float


func _fail(p_key: String, p_index: int, p_error: String) -> Dictionary:
	return {"kind": "select", "at": p_index, "key": p_key, "sel": [], "error": p_error}
