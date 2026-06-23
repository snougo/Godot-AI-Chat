@tool
extends AiTool

## Generates and executes a custom EditorScript for complex editor operations.
## All safety checks are centralized here: master switch → static analysis → snapshot diff audit.
## LLMs write standard `extends EditorScript` code — no special base class required.

# --- Constants ---

const DANGEROUS_PATTERNS: Array[Dictionary] = [
	{
		"pattern": "OS.execute(",
		"level": "block",
		"message": "OS.execute() is forbidden — cannot spawn external processes."
	},
	{
		"pattern": "OS.create_process(",
		"level": "block",
		"message": "OS.create_process() is forbidden."
	},
	{
		"pattern": "OS.shell_open(",
		"level": "block",
		"message": "OS.shell_open() is forbidden — cannot open external applications."
	},
	{
		"pattern": "OS.kill(",
		"level": "block",
		"message": "OS.kill() is forbidden."
	},
	{
		"pattern": "OS.set_environment(",
		"level": "block",
		"message": "OS.set_environment() is forbidden."
	},
	{
		"pattern": "DirAccess.remove_absolute(",
		"level": "block",
		"message": "DirAccess.remove_absolute() is forbidden — cannot delete directories."
	},
	{
		"pattern": "EditorInterface.restart_editor(",
		"level": "block",
		"message": "EditorInterface.restart_editor() is forbidden."
	},
]

const RESTRICTED_PATH_PATTERNS: Array[String] = [
	"res://addons/",
	"res://.godot/",
	"res://.git/",
	"res://.import/",
	"res://android/",
]

# --- Built-in Functions ---

func _init() -> void:
	tool_name = "run_editor_script"
	tool_description = "Generates and executes a custom Editor script. Use for complex, non-standard operations only — DO NOT ABUSE!"

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


func execute(p_args: Dictionary) -> Dictionary:
	# === Layer 0: Master switch ===
	var _cfg: PluginSettingsConfig = ToolBox.get_plugin_settings()
	if not _cfg.allow_editor_script_execution:
		return {
			"success": false,
			"data": "⛔ **Editor Script execution is disabled.**\n\n"
				  + "Please describe to the user what you intend to do, "
				  + "and ask them to enable the **'Run EditorScript'** CheckButton in the Chat UI."
		}
	
	# === Layer 1: Static code analysis ===
	var code: String = p_args.get("code", "")
	if code.is_empty():
		return {"success": false, "data": "Error: 'code' parameter is required."}
	
	var static_result: Dictionary = _static_analysis(code)
	if not static_result.success:
		return static_result
	
	# === Layer 2: Pre-execution file system snapshot ===
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Error: run_editor_script can only be used in the Godot editor."}
	
	var snapshot_before: Dictionary = _collect_file_snapshot()
	
	# === Layer 3: Compile and execute ===
	var wrapped_code: String = _wrap_code(code)
	var script: GDScript = _compile_script(wrapped_code)
	if not script:
		return {"success": false, "data": "❌ **Script compilation failed.** Check syntax and Godot API usage."}
	
	var instance: Variant = script.new()
	if not instance or not instance is EditorScript:
		return {"success": false, "data": "❌ **Script instantiation failed.** Code must extend EditorScript."}
	
	instance._run()
	
	# === Layer 4: Post-execution snapshot + audit ===
	var snapshot_after: Dictionary = _collect_file_snapshot()
	var audit: Dictionary = _diff_snapshots(snapshot_before, snapshot_after)
	
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
	if not audit.restricted_violations.is_empty():
		result_text += "**⛔ Restricted Zone Violations:**\n"
		for v in audit.restricted_violations:
			result_text += "- %s\n" % v
		result_text += "\n"
	
	if _is_empty(audit):
		result_text += "*(No file system changes detected.)*\n"
	
	# Refresh editor filesystem
	ToolBox.refresh_editor_filesystem()
	
	if static_result.has("warnings") and not static_result.warnings.is_empty():
		result_text += "**Static Analysis Warnings:**\n"
		for w in static_result.warnings:
			result_text += "- %s\n" % w
	
	return {"success": true, "data": result_text}


# --- Private Functions ---

func _static_analysis(p_code: String) -> Dictionary:
	var blocks: Array[String] = []
	var warns: Array[String] = []
	
	for rule in DANGEROUS_PATTERNS:
		if rule.pattern in p_code:
			if rule.level == "block":
				blocks.append(rule.message)
			elif rule.level == "warn":
				warns.append(rule.message)
	
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
	var script: GDScript = GDScript.new()
	script.source_code = p_code
	var err: Error = script.reload()
	if err != OK:
		printerr("[run_editor_script] Compilation error: ", err)
		return null
	return script


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
	var violations: Array[String] = []
	
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
	
	# Restricted zone violation detection
	for path in created + modified:
		for prefix in RESTRICTED_PATH_PATTERNS:
			if path.begins_with(prefix):
				violations.append("Restricted zone modified: %s" % path)
				break
	
	return {
		"created": created,
		"modified": modified,
		"deleted": deleted,
		"restricted_violations": violations
	}


func _is_empty(p_dict: Dictionary) -> bool:
	return p_dict.created.is_empty() and p_dict.modified.is_empty() and p_dict.deleted.is_empty() and p_dict.restricted_violations.is_empty()
