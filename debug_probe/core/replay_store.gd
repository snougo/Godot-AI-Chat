extends RefCounted

# Baseline storage for the "replay" plan key: one JSON file per replay id under user://, so a
# baseline recorded before a code change is still there after the editor restarts the game.
#
# Kept deliberately dumb (load / save / clear) and free of diffing: comparing belongs to
# core/diff.gd, and the step runner decides which of the two to use.

# --- Constants ---

const DIR: String = "user://ai_debug_probe_replay"

# --- Public Functions ---

# The stored record, or an empty dictionary when there is none.
static func load_record(p_id: String) -> Dictionary:
	var path: String = path_of(p_id)
	if not FileAccess.file_exists(path):
		return {}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text: String = file.get_as_text()
	file.close()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {}
	return parsed


static func save(p_id: String, p_record: Dictionary) -> Error:
	var err: int = DirAccess.make_dir_recursive_absolute(DIR)
	if err != OK and err != ERR_ALREADY_EXISTS:
		return err as Error
	var file: FileAccess = FileAccess.open(path_of(p_id), FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_string(JSON.stringify(p_record))
	file.close()
	return OK


static func clear(p_id: String) -> bool:
	var path: String = path_of(p_id)
	if not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(path) == OK


static func path_of(p_id: String) -> String:
	return "%s/%s.json" % [DIR, _slug(p_id)]

# --- Private Functions ---

# The id becomes a file name, so anything that is not a plain word is folded to "_".
static func _slug(p_id: String) -> String:
	var out: String = ""
	for i: int in p_id.length():
		var c: String = p_id[i]
		var code: int = c.unicode_at(0)
		var is_word: bool = (code >= 48 and code <= 57) or (code >= 65 and code <= 90) \
				or (code >= 97 and code <= 122) or c == "_" or c == "-"
		out += c if is_word else "_"
	return out if not out.is_empty() else "default"
