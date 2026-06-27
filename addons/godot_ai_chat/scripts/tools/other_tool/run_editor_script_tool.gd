@tool
extends AiTool

## Generates and executes a custom EditorScript for complex editor operations.
## All safety checks are centralized here: master switch → static analysis → format whitelist → snapshot diff audit.
## LLMs write standard `extends EditorScript` code — no special base class required.

# --- Constants ---

## Network APIs — block on sight (data exfiltration risk).
const DANGEROUS_TYPES: Array[String] = [
	"HTTPRequest", "HTTPClient", "WebSocketPeer", "StreamPeerTCP",
	"StreamPeerTLS", "TCPServer", "PacketPeerUDP",
]

## Wildcard block — method name alone is dangerous, regardless of calling object.
const DANGEROUS_METHODS_BLOCK: Array[Dictionary] = [
	{"method": "execute", "message": "execute() is forbidden — cannot spawn external processes."},
	{"method": "create_process", "message": "create_process() is forbidden."},
	{"method": "shell_open", "message": "shell_open() is forbidden — cannot open external applications."},
	{"method": "kill", "message": "kill() is forbidden."},
	{"method": "set_environment", "message": "set_environment() is forbidden."},
	{"method": "get_environment", "message": "get_environment() is forbidden — cannot read environment variables (may contain secrets)."},
	{"method": "remove_absolute", "message": "remove_absolute() is forbidden — cannot delete files."},
	{"method": "rename_absolute", "message": "rename_absolute() is forbidden — cannot rename/move files (may overwrite targets)."},
	{"method": "copy_absolute", "message": "copy_absolute() is forbidden — cannot copy files (may overwrite targets)."},
	{"method": "restart_editor", "message": "restart_editor() is forbidden."},
]

## Typed block — requires alias tracking to resolve object type before matching method.
const DANGEROUS_TYPED_CALLS: Array[Dictionary] = [
	{"object": "DirAccess", "method": "remove", "message": "DirAccess.remove() is forbidden — cannot delete files."},
	{"object": "DirAccess", "method": "rename", "message": "DirAccess.rename() is forbidden — cannot rename/move files."},
	{"object": "DirAccess", "method": "copy", "message": "DirAccess.copy() is forbidden — cannot copy files (may overwrite targets)."},
]

## Wildcard warn — method name triggers warning regardless of calling object.
const WARN_METHODS: Array[Dictionary] = [
	{"method": "set_setting", "message": "set_setting() detected — changes to editor/project settings are not auditable by file snapshot."},
]

## Objects whose .call()/.callv() must be blocked (dynamic method invocation bypass).
const DANGEROUS_DYNAMIC_CALL_OBJECTS: Array[String] = [
	"OS", "DirAccess", "EditorInterface", "ProjectSettings", "Engine",
]

## FileAccess methods that take a file path as first argument — restricted to res:// only.
const FILEACCESS_PATH_METHODS: Array[String] = [
	"open", "open_compressed", "open_encrypted", "open_encrypted_with_pass",
	"get_file_as_string", "file_exists", "get_modified_time", "get_md5",
]

## Whitelist of file extensions that the EditorScript is allowed to create/modify.
const ALLOWED_EXTENSIONS: Array[String] = [
	"md", "json", "txt", "csv", 
	"gdshader", "glsl",
	"tscn", "tres",
	"gltf", "obj", "fbx"
]

## Restricted zones — files inside these directories are off-limits regardless of format.
const RESTRICTED_PATH_PATTERNS: Array[String] = [
	"res://addons/",
	"res://.godot/",
	"res://.git/",
	"res://.import/",
	"res://android/",
]

# --- Private Vars ---

# Stores the exact compiler error text captured from EditorLog.
var _last_compile_error: String = ""


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "run_editor_script"
	tool_description = "Executes a custom Editor script. This tool is disabled by default."
	security_level = SecurityLevel.NONE


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"code": {
				"type": "string",
				"description": "The GDScript code to execute. Must extend EditorScript and override _run(). DO NOT include class_name."
			}
		},
		"required": ["code"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	# === Layer 0: Master switch ===
	var _cfg: PluginSettingsConfig = ToolBox.get_plugin_settings()
	if not _cfg.allow_editor_script_execution:
		return ToolResult.fail("⛔ **Editor Script execution is disabled.**\n\n"
			  + "Please describe to the user what you intend to do, "
			  + "and ask them to enable the **PandoraBox** CheckButton in the Chat UI.")
	
	# === Layer 1: Static code analysis (L2 — call extraction + alias tracking) ===
	var code: String = p_args.get("code", "")
	if code.is_empty():
		return ToolResult.fail("Error: 'code' parameter is required.")
	
	var static_result: Dictionary = _static_analysis_l2(code)
	if not static_result.success:
		return ToolResult.fail(static_result.data)
	
	# === Layer 1.5: Pre-execution format whitelist (static scan) ===
	var whitelist_result: Dictionary = _check_format_whitelist(code)
	if not whitelist_result.success:
		return ToolResult.fail(whitelist_result.data)
	
	# === Layer 2: Pre-execution file system snapshot ===
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: run_editor_script can only be used in the Godot editor.")
	
	var snapshot_before: Dictionary = _collect_file_snapshot()
	
	# === Layer 3: Compile and execute ===
	var wrapped_code: String = _wrap_code(code)
	var script: GDScript = _compile_script(wrapped_code)
	if not script:
		return ToolResult.fail("❌ **Script compilation failed.** " + (_last_compile_error if not _last_compile_error.is_empty() else "Check syntax and Godot API usage."))
	
	var instance: Variant = script.new()
	if not instance or not instance is EditorScript:
		return ToolResult.fail("❌ **Script instantiation failed.** Code must extend EditorScript.")
	
	instance._run()
	
	# === Layer 4: Post-execution snapshot + dual audit ===
	var snapshot_after: Dictionary = _collect_file_snapshot()
	var audit: Dictionary = _diff_snapshots(snapshot_before, snapshot_after)
	
	# --- Post-execution audit: format whitelist — created/modified (catch B1 bypass) ---
	var post_violations: Array[String] = []
	for path in audit.created + audit.modified:
		var ext: String = path.get_extension().to_lower()
		if ext.is_empty():
			continue
		if not ext in ALLOWED_EXTENSIONS:
			post_violations.append("- `%s` (格式: `.%s`, 操作: 创建/修改) — 不在白名单内" % [path, ext])
	
	# --- Post-execution audit: format whitelist — deleted (prevent source file destruction) ---
	for path in audit.deleted:
		var ext: String = path.get_extension().to_lower()
		if ext.is_empty():
			continue
		if not ext in ALLOWED_EXTENSIONS:
			post_violations.append("- `%s` (格式: `.%s`, 操作: 删除) — 不允许删除非白名单格式文件" % [path, ext])
	
	# --- Post-execution audit: path blacklist (all changes: create/modify/delete) ---
	for path in audit.created + audit.modified + audit.deleted:
		for prefix in RESTRICTED_PATH_PATTERNS:
			if path.begins_with(prefix):
				post_violations.append("- `%s` — 位于受限区域 `%s`" % [path, prefix])
				break
	
	if not post_violations.is_empty():
		var ext_list: String = ""
		for e in ALLOWED_EXTENSIONS:
			ext_list += "- `.%s`\n" % e
		return ToolResult.fail("⛔ **Security violations detected after execution.**\n\n"
				  + "The following unauthorized file operations were detected:\n"
				  + "\n".join(post_violations) + "\n\n"
				  + "**Allowed file formats:**\n"
				  + ext_list
				  + "\n**Restricted zones:**\n"
				  + "- `res://addons/`\n"
				  + "- `res://.godot/`\n"
				  + "- `res://.git/`\n"
				  + "- `res://.import/`\n"
				  + "- `res://android/`\n"
		)
	
	# --- Report normal changes ---
	var result_text: String = "✅ **Editor Script executed successfully.**\n\n"
	
	if not audit.created.is_empty():
		result_text += "**Files Created:**\n"
		for f in audit.created:
			result_text += "- `%s`\n" % f
		result_text += "\n"
	if not audit.modified.is_empty():
		result_text += "**Files Modified:**\n"
		for f in audit.modified:
			result_text += "- `%s`\n" % f
		result_text += "\n"
	if not audit.deleted.is_empty():
		result_text += "**Files Deleted:**\n"
		for f in audit.deleted:
			result_text += "- `%s`\n" % f
		result_text += "\n"
	
	if _is_empty(audit):
		result_text += "*(No file system changes detected.)*\n"
	
	ToolBox.refresh_editor_filesystem()
	
	if static_result.has("warnings") and not static_result.warnings.is_empty():
		result_text += "**Static Analysis Warnings:**\n"
		for w in static_result.warnings:
			result_text += "- %s\n" % w
	
	return ToolResult.ok(result_text)


# --- Private Functions: L2 Static Analysis ---

# Strips string literals and comments from code for structural analysis.
# String contents are replaced with empty placeholders; comments are removed entirely.
func _strip_strings_and_comments(p_code: String) -> String:
	var code := p_code
	
	# Strip string literals (double-quoted and single-quoted)
	var dq_pattern: RegEx = RegEx.create_from_string('"[^"]*"')
	var sq_pattern: RegEx = RegEx.create_from_string("'[^']*'")
	code = dq_pattern.sub(code, '""', true)
	code = sq_pattern.sub(code, "''", true)
	
	# Strip comments (remove everything after # on each line)
	var lines := code.split("\n")
	for i in lines.size():
		var hash_pos: int = lines[i].find("#")
		if hash_pos != -1:
			lines[i] = lines[i].substr(0, hash_pos)
	return "\n".join(lines)


# Builds a symbol table mapping variable names to their resolved type/source.
# Only extracts the leading identifier from assignment right-hand sides.
func _build_symbol_table(p_code: String) -> Dictionary:
	var table: Dictionary = {}
	# Match: [var] X [: Type] = RHS  (but NOT ==, <=, >=, !=)
	var assign_pattern: RegEx = RegEx.create_from_string(
		"(?:var\\s+)?(\\w+)\\s*(?::\\s*[\\w\\.]+\\s*)?(?::=|=(?!=))\\s*(.+)"
	)
	
	for match in assign_pattern.search_all(p_code):
		var var_name: String = match.get_string(1)
		var rhs: String = match.get_string(2).strip_edges()
		var resolved: String = _resolve_rhs(rhs)
		if not resolved.is_empty():
			table[var_name] = resolved
	
	return table


# Extracts the leading type/source identifier from an assignment right-hand side.
# - `HTTPRequest.new()` → "HTTPRequest"
# - `DirAccess.open(...)` → "DirAccess"
# - `some_var` → "some_var" (caller resolves via symbol table)
# - `5`, `"text"`, `func():...` → "" (ignored)
func _resolve_rhs(p_rhs: String) -> String:
	p_rhs = p_rhs.strip_edges()
	
	# Case 1: ClassName.xxx( → extract ClassName
	var call_match: RegEx = RegEx.create_from_string("^(\\w+)\\.")
	var cm: RegExMatch = call_match.search(p_rhs)
	if cm:
		return cm.get_string(1)
	
	# Case 2: Pure identifier → return as-is (may be a variable alias or type name)
	var id_match: RegEx = RegEx.create_from_string("^(\\w+)$")
	var im: RegExMatch = id_match.search(p_rhs)
	if im:
		return im.get_string(1)
	
	# Case 3: Other (literal, expression, etc.) → ignore
	return ""


# Resolves chained variable aliases in the symbol table until convergence.
# Example: {d2 → d, d → DirAccess} → {d2 → DirAccess, d → DirAccess}
func _resolve_symbol_table(p_table: Dictionary) -> Dictionary:
	var resolved: Dictionary = p_table.duplicate()
	var changed: bool = true
	var iterations: int = 0
	
	while changed and iterations < 10:
		changed = false
		iterations += 1
		for key in resolved:
			var val: String = resolved[key]
			if val != key and resolved.has(val):
				resolved[key] = resolved[val]
				changed = true
	
	return resolved


# Extracts all method-call expressions of the form `identifier.method(` from code.
# Returns a deduplicated list of {object, method} pairs.
func _extract_calls(p_code: String) -> Array[Dictionary]:
	var calls: Array[Dictionary] = []
	var seen: Dictionary = {}
	var call_pattern: RegEx = RegEx.create_from_string("(\\w+)\\.(\\w+)\\s*\\(")
	
	for match in call_pattern.search_all(p_code):
		var obj: String = match.get_string(1)
		var method: String = match.get_string(2)
		var key: String = obj + "." + method
		if not seen.has(key):
			seen[key] = true
			calls.append({"object": obj, "method": method})
	
	return calls


# L2 static analysis: preprocess → symbol table → call extraction → danger check.
func _static_analysis_l2(p_code: String) -> Dictionary:
	var blocks: Array[String] = []
	var warns: Array[String] = []
	
	# 1. Preprocess: strip strings and comments
	var clean_code: String = _strip_strings_and_comments(p_code)
	
	# 2. Build and resolve symbol table
	var raw_table: Dictionary = _build_symbol_table(clean_code)
	var symbol_table: Dictionary = _resolve_symbol_table(raw_table)
	
	# 3. Extract all method calls
	var calls: Array[Dictionary] = _extract_calls(clean_code)
	
	# 4. Check each call against danger rules
	for call in calls:
		var obj: String = call["object"]
		var method: String = call["method"]
		# Resolve object through symbol table (fall back to raw name if not a tracked variable)
		var resolved_obj: String = symbol_table.get(obj, obj)
		
		# 4a. Check DANGEROUS_TYPES
		if resolved_obj in DANGEROUS_TYPES:
			blocks.append("%s is forbidden — network APIs are not allowed." % resolved_obj)
			continue
		
		# 4b. Check DANGEROUS_TYPED_CALLS (object + method)
		var typed_hit: bool = false
		for rule in DANGEROUS_TYPED_CALLS:
			if resolved_obj == rule["object"] and method == rule["method"]:
				blocks.append(rule["message"])
				typed_hit = true
				break
		if typed_hit:
			continue
		
		# 4c. Check DANGEROUS_METHODS_BLOCK (wildcard method)
		var method_hit: bool = false
		for rule in DANGEROUS_METHODS_BLOCK:
			if method == rule["method"]:
				blocks.append(rule["message"])
				method_hit = true
				break
		if method_hit:
			continue
		
		# 4d. Check dangerous dynamic calls (.call()/.callv() on known dangerous objects)
		if (method == "call" or method == "callv") and resolved_obj in DANGEROUS_DYNAMIC_CALL_OBJECTS:
			blocks.append("%s.%s() is forbidden — cannot dynamically invoke methods on %s." % [resolved_obj, method, resolved_obj])
			continue
		
		# 4e. Check WARN_METHODS
		for rule in WARN_METHODS:
			if method == rule["method"]:
				warns.append(rule["message"])
				break
	
	# 5. Check FileAccess path whitelist — restrict to res:// only
	var fa_result: Dictionary = _check_fileaccess_paths(p_code, symbol_table)
	if not fa_result.success:
		return fa_result
	if fa_result.has("warnings"):
		for w in fa_result["warnings"]:
			warns.append(w)
	
	# 6. Build result
	if not blocks.is_empty():
		var msg: String = "**Static analysis blocked execution.**\n\nThe following forbidden patterns were detected:\n"
		for b in blocks:
			msg += "- %s\n" % b
		msg += "\nRewrite the code without these operations."
		return {"success": false, "data": msg}
	
	var result: Dictionary = {"success": true}
	if not warns.is_empty():
		result["warnings"] = warns
	return result


# --- Private Functions: FileAccess Path Whitelist (Layer 1) ---

# Checks that all FileAccess path-taking methods use res:// paths only.
# Runs on original code (not stripped) to inspect string literal arguments.
# Also checks aliases resolved to FileAccess via the symbol table.
func _check_fileaccess_paths(p_code: String, p_symbol_table: Dictionary) -> Dictionary:
	var blocks: Array[String] = []
	var warns: Array[String] = []
	
	# Identifiers that resolve to FileAccess (always includes the class name itself)
	var fa_names: Array[String] = ["FileAccess"]
	for key in p_symbol_table:
		if p_symbol_table[key] == "FileAccess":
			fa_names.append(key)
	
	for alias in fa_names:
		# 1. Double-quoted string argument
		var dq_pat: RegEx = RegEx.create_from_string(alias + '\\.(\\w+)\\s*\\(\\s*"([^"]*)"')
		for match in dq_pat.search_all(p_code):
			var method: String = match.get_string(1)
			if method not in FILEACCESS_PATH_METHODS:
				continue
			var path: String = match.get_string(2)
			if not path.begins_with("res://"):
				blocks.append('FileAccess.%s() — path "%s" is outside res:// — only project files are allowed.' % [method, path])
		
		# 2. Single-quoted string argument
		var sq_pat: RegEx = RegEx.create_from_string(alias + "\\.(\\w+)\\s*\\(\\s*'([^']*)'")
		for match in sq_pat.search_all(p_code):
			var method: String = match.get_string(1)
			if method not in FILEACCESS_PATH_METHODS:
				continue
			var path: String = match.get_string(2)
			if not path.begins_with("res://"):
				blocks.append("FileAccess.%s() — path '%s' is outside res:// — only project files are allowed." % [method, path])
		
		# 3. Non-string-literal argument (dynamic path, cannot verify)
		var dyn_pat: RegEx = RegEx.create_from_string(alias + '\\.(\\w+)\\s*\\(\\s*[^"\'\\s)]')
		var dyn_seen: Dictionary = {}
		for match in dyn_pat.search_all(p_code):
			var method: String = match.get_string(1)
			if method not in FILEACCESS_PATH_METHODS:
				continue
			if not dyn_seen.has(method):
				dyn_seen[method] = true
				warns.append("FileAccess.%s() uses a non-literal path — cannot verify it's within res://." % method)
	
	if not blocks.is_empty():
		var msg: String = "**Static analysis blocked execution.**\n\nThe following forbidden file access was detected:\n"
		for b in blocks:
			msg += "- %s\n" % b
		msg += "\nFileAccess is restricted to res:// paths only."
		return {"success": false, "data": msg}
	
	var result: Dictionary = {"success": true}
	if not warns.is_empty():
		result["warnings"] = warns
	return result


# --- Private Functions: Format Whitelist (Layer 1.5) ---

func _check_format_whitelist(p_code: String) -> Dictionary:
	# Scans code for all string literals containing file-like paths (both
	# full res:// paths and relative filenames) and validates extensions
	# against the whitelist. Also detects format-string bypass attempts
	# (e.g. "res://file.%s" % "gd").
	var pattern: RegEx = RegEx.create_from_string('"([^"]*)\\.([a-zA-Z0-9_]+)"')
	var sq_pattern: RegEx = RegEx.create_from_string("'([^']*)\\.([a-zA-Z0-9_]+)'")
	var fmt_pattern: RegEx = RegEx.create_from_string('"(res://[^"]*%[a-zA-Z][^"]*)"')
	var sq_fmt_pattern: RegEx = RegEx.create_from_string("'(res://[^']*%[a-zA-Z][^']*)'")
	
	var violations: Array[String] = []
	var seen: Array[String] = []
	
	# Check double-quoted strings (standard file.ext pattern)
	for match in pattern.search_all(p_code):
		var full: String = match.get_string(0)
		if full in seen:
			continue
		seen.append(full)
		var ext: String = match.get_string(2).to_lower()
		if not ext in ALLOWED_EXTENSIONS:
			violations.append("- `%s` (格式: `.%s`)" % [full, ext])
	
	# Check single-quoted strings (standard file.ext pattern)
	for match in sq_pattern.search_all(p_code):
		var full: String = match.get_string(0)
		if full in seen:
			continue
		seen.append(full)
		var ext: String = match.get_string(2).to_lower()
		if not ext in ALLOWED_EXTENSIONS:
			violations.append("- `%s` (格式: `.%s`)" % [full, ext])
	
	# Check format-string bypass (double-quoted, e.g. "file.%s" or "file_%s.gd")
	for match in fmt_pattern.search_all(p_code):
		var path: String = match.get_string(1)
		if path in seen:
			continue
		seen.append(path)
		var last_dot: int = path.rfind(".")
		if last_dot == -1:
			continue
		var after_dot: String = path.substr(last_dot + 1)
		if "%" in after_dot:
			violations.append("- `%s` (扩展名含动态格式符，无法确定最终格式)" % ['"' + path + '"'])
	
	# Check format-string bypass (single-quoted)
	for match in sq_fmt_pattern.search_all(p_code):
		var path: String = match.get_string(1)
		if path in seen:
			continue
		seen.append(path)
		var last_dot: int = path.rfind(".")
		if last_dot == -1:
			continue
		var after_dot: String = path.substr(last_dot + 1)
		if "%" in after_dot:
			violations.append("- `%s` (扩展名含动态格式符，无法确定最终格式)" % ["'" + path + "'"])
	
	if violations.is_empty():
		return {"success": true}
	
	var ext_list: String = ""
	for e in ALLOWED_EXTENSIONS:
		ext_list += "- `.%s`\n" % e
	
	return {
		"success": false,
		"data": "⛔ **Permission Denied: Unsupported file format.**\n\n"
			  + "The generated code references file formats not in the allowed whitelist.\n"
			  + "**Violations:**\n"
			  + "\n".join(violations) + "\n\n"
			  + "**Allowed file formats:**\n"
			  + ext_list
			  + "\nPlease rewrite the code to only work with allowed file formats."
	}


# --- Private Functions: Code Wrapping & Compilation ---

func _wrap_code(p_code: String) -> String:
	var clean_code: String = p_code.strip_edges()
	
	# Ensure extends EditorScript
	if "extends EditorScript" not in clean_code:
		clean_code = "extends EditorScript\n\n" + clean_code
	
	# Remove class_name (not allowed for ephemeral scripts)
	var class_name_regex: RegEx = RegEx.create_from_string("(?m)^class_name\\s+\\w+\\s*$")
	clean_code = class_name_regex.sub(clean_code, "", true)
	
	# Ensure @tool
	if not clean_code.begins_with("@tool"):
		clean_code = "@tool\n" + clean_code
	
	return clean_code


func _compile_script(p_code: String) -> GDScript:
	_last_compile_error = ""
	
	var editor_log: RichTextLabel = _get_editor_log()
	var before_text: String = editor_log.get_parsed_text() if editor_log else ""
	
	var script: GDScript = GDScript.new()
	script.source_code = p_code
	var err: Error = script.reload()
	
	if err != OK:
		if editor_log:
			var after_text: String = editor_log.get_parsed_text()
			var captured: String = _capture_editor_log_error(before_text, after_text)
			if not captured.is_empty():
				_last_compile_error = captured
		
		printerr("[run_editor_script] Compilation error: ", err)
		return null
	
	return script


# --- Private Functions: File System Snapshot & Audit (Layer 4) ---

func _collect_file_snapshot() -> Dictionary:
	var snapshot: Dictionary = {}
	_collect_files_recursive("res://", snapshot)
	return snapshot


func _collect_files_recursive(p_dir: String, p_snapshot: Dictionary) -> void:
	var dir: DirAccess = DirAccess.open(p_dir)
	if not dir:
		return
	
	dir.list_dir_begin()
	var item: String = dir.get_next()
	while item != "":
		if item.begins_with("."):
			item = dir.get_next()
			continue
		
		var full_path: String = p_dir.path_join(item)
		if dir.current_is_dir():
			_collect_files_recursive(full_path + "/", p_snapshot)
		else:
			p_snapshot[full_path] = FileAccess.get_modified_time(full_path)
		item = dir.get_next()
	dir.list_dir_end()


func _diff_snapshots(p_before: Dictionary, p_after: Dictionary) -> Dictionary:
	var created: Array[String] = []
	var modified: Array[String] = []
	var deleted: Array[String] = []
	
	# Created / Modified
	for path in p_after:
		if not p_before.has(path):
			created.append(path)
		elif p_after[path] != p_before[path]:
			modified.append(path)
	
	# Deleted
	for path in p_before:
		if not p_after.has(path):
			deleted.append(path)
	
	return {
		"created": created,
		"modified": modified,
		"deleted": deleted,
	}


func _is_empty(p_dict: Dictionary) -> bool:
	return p_dict.created.is_empty() and p_dict.modified.is_empty() and p_dict.deleted.is_empty()


# --- Private Functions: EditorLog Error Capture ---

# Retrieves the EditorLog RichTextLabel node from the editor UI tree.
# Returns null if not in editor mode or if the node cannot be found.
func _get_editor_log() -> RichTextLabel:
	if not Engine.is_editor_hint():
		return null
	var base_control: Control = EditorInterface.get_base_control()
	if not base_control:
		return null
	
	# Strategy 1: Find EditorLog by class name (works in 4.7+)
	var logs: Array[Node] = base_control.find_children("*", "EditorLog", true, false)
	for log_node in logs:
		var rtls: Array[Node] = log_node.find_children("*", "RichTextLabel", true, false)
		if rtls.size() > 0:
			return rtls[0] as RichTextLabel
	
	# Strategy 2: Find by node name "Output" (fallback)
	var output_node: Node = base_control.find_child("Output", true, false)
	if output_node:
		var rtls: Array[Node] = output_node.find_children("*", "RichTextLabel", true, false)
		if rtls.size() > 0:
			return rtls[0] as RichTextLabel
	
	# Strategy 3: Old name fallback
	var log: RichTextLabel = base_control.find_child("EditorLog", true, false) as RichTextLabel
	if log:
		return log
	
	return null


# Extracts newly appended text from EditorLog by comparing before/after snapshots.
# The new text typically contains Godot's exact compiler error message,
# e.g. "res://.gd:5: Parse Error: Expected ')'"
func _capture_editor_log_error(p_before: String, p_after: String) -> String:
	var new_text: String = ""
	if p_after.length() > p_before.length():
		new_text = p_after.substr(p_before.length())
	elif p_before.is_empty():
		new_text = p_after
	
	new_text = new_text.strip_edges()
	if new_text.is_empty():
		return ""
	
	# Filter out noise: only keep lines that look like compile errors
	var lines: PackedStringArray = new_text.split("\n")
	var filtered: PackedStringArray = []
	for line in lines:
		var trimmed: String = line.strip_edges()
		if trimmed.is_empty():
			continue
		if "Parse Error" in trimmed \
		or "Parse error" in trimmed \
		or "Compile Error" in trimmed \
		or "SCRIPT ERROR" in trimmed \
		or trimmed.begins_with("  ") \
		or trimmed.begins_with("at:"):
			filtered.append(trimmed)
	
	if filtered.is_empty():
		return new_text
	
	return "\n".join(filtered)
