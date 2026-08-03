@tool
extends AiTool

## Generates and executes a custom EditorScript for complex editor operations.
## Safety model: AI declares intended file paths → tool validates paths →
## verifies code-only-uses-declared-paths → executes → audits.

# ============================================================================
# Constants — Danger Rules
# ============================================================================

## Network-related classes — block all usage (data exfiltration risk).
const DANGEROUS_NETWORK_CLASSES: Array[String] = [
	"HTTPRequest", 
	"HTTPClient", 
	"WebSocketPeer", 
	"StreamPeerTCP",
	"StreamPeerTLS", 
	"TCPServer", 
	"PacketPeerUDP",
]

## High-risk classes — ALL method calls on these classes are blocked.
## API surface is too broad or invasive for selective blocking.
const BLOCKED_CLASSES: Array[String] = [
	"OS",
	"EditorInterface",
	"ProjectSettings",
	"Engine",
	"EditorFileSystem",
	"ScriptEditor",
]

## Partially blocked classes — only specific methods are forbidden.
## Requires alias tracking to resolve object type before matching method.
const DANGEROUS_TYPED_CALLS: Array[Dictionary] = [
	# DirAccess — file system manipulation
	{"object": "DirAccess", "method": "remove", "message": "DirAccess.remove() is forbidden — cannot delete files."},
	{"object": "DirAccess", "method": "rename", "message": "DirAccess.rename() is forbidden — cannot rename/move files."},
	{"object": "DirAccess", "method": "copy", "message": "DirAccess.copy() is forbidden — cannot copy files (may overwrite targets)."},
	{"object": "DirAccess", "method": "remove_absolute", "message": "DirAccess.remove_absolute() is forbidden — cannot delete files."},
	{"object": "DirAccess", "method": "rename_absolute", "message": "DirAccess.rename_absolute() is forbidden — cannot rename/move files."},
	{"object": "DirAccess", "method": "copy_absolute", "message": "DirAccess.copy_absolute() is forbidden — cannot copy files (may overwrite targets)."},
	{"object": "DirAccess", "method": "make_dir_recursive", "message": "DirAccess.make_dir_recursive() is forbidden — cannot create directories."},
	{"object": "DirAccess", "method": "make_dir_recursive_absolute", "message": "DirAccess.make_dir_recursive_absolute() is forbidden — cannot create directories."},
	{"object": "ClassDB", "method": "instantiate", "message": "ClassDB.instantiate() is forbidden — dynamic class instantiation bypasses static analysis."},
	{"object": "ClassDB", "method": "instance", "message": "ClassDB.instance() is forbidden — dynamic class instantiation bypasses static analysis."},
]

# ============================================================================
# Constants — Path & File Validation
# ============================================================================

## Whitelist of file extensions that the EditorScript is allowed to create/modify.
const ALLOWED_EXTENSIONS: Array[String] = [
	"md", "json", "txt", "csv", "cfg",
	"gdshader", "glsl",
	"tres",
	"tscn", "gd",
	"svg"
]

## Restricted zones — files inside these directories are off-limits regardless of format.
const RESTRICTED_PATH_PATTERNS: Array[String] = [
	"res://addons/",
	"res://.godot/",
	"res://.git/",
	"res://.import/",
	"res://android/",
	"res://rollback_files/",
]

## Max file size (bytes) for content backup — skip files larger than this.
const MAX_BACKUP_SIZE: int = 5 * 1024 * 1024  # 5MB


# --- Private Vars ---

# Stores the exact compiler error text captured from EditorLog.
var _last_compile_error: String = ""


# ============================================================================
# Built-in Functions
# ============================================================================

func _init() -> void:
	tool_name = "run_editor_script"
	tool_description = "Executes a custom Editor script. This tool is disabled by default."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_paths": {
				"type": "array",
				"items": {"type": "string"},
				"description": "List of file paths this script will operate on. All \"res://\" paths in the code must appear in this list."
			},
			"code": {
				"type": "string",
				"description": "The GDScript code to execute. Must extend `EditorScript` and override `_run()`. Do NOT include class_name."
			}
		},
		"required": ["file_paths", "code"]
	}


# ============================================================================
# Main Execution
# ============================================================================

func execute(p_args: Dictionary) -> ToolResult:
	# === Layer 0: Master switch ===
	var _cfg: PluginSettingsConfig = ToolBox.get_plugin_settings()
	if not _cfg.allow_editor_script_execution:
		return ToolResult.fail(
			"**Editor Script execution is disabled.**\n\n"
			+ "Please describe to the user what you intend to do, and ask user to enable the **PandoraBox** CheckButton in the Chat UI."
		)
	
	var code: String = p_args.get("code", "")
	var file_paths: Array = p_args.get("file_paths", [])
	
	if code.is_empty():
		return ToolResult.fail("'code' parameter is required.")
	if file_paths.is_empty():
		return ToolResult.fail("'file_paths' parameter is required — declare at least one file path.")
	
	# === Layer 1A: Validate declared paths (pure parameter check) ===
	var path_validation: ToolResult = _validate_declared_paths(file_paths)
	if path_validation.is_fail():
		return path_validation
	
	# === Layer 1B: Static analysis (danger APIs) ===
	var static_result: ToolResult = _static_analysis_l2(code)
	if static_result.is_fail():
		return static_result
	
	# === Layer 1C: Verify code paths match declared set ===
	var verify_result: ToolResult = _verify_code_paths(code, file_paths)
	if verify_result.is_fail():
		return verify_result
	
	# === Layer 1D: Check for non-literal API calls (dynamic paths) ===
	var dynamic_result: ToolResult = _check_dynamic_api_calls(code, file_paths)
	if dynamic_result.is_fail():
		return dynamic_result
	
	# === Layer 1.75: Backup declared paths ===
	var backup_targets: Dictionary = {"write": file_paths, "delete": file_paths}
	var target_backup: Dictionary = _backup_target_files(backup_targets)
	var backup_id: String = _generate_backup_id()
	_save_backup_to_disk(backup_id, code, file_paths, target_backup)
	
	# === Layer 2: Pre-execution file system snapshot ===
	if not Engine.is_editor_hint():
		return ToolResult.fail("`run_editor_script` can only be used in the Godot editor.")
	
	var snapshot_before: Dictionary = _collect_file_snapshot()
	
	# === Layer 3: Compile and execute ===
	var wrapped_code: String = _wrap_code(code)
	var script: GDScript = _compile_script(wrapped_code)
	if not script:
		return ToolResult.fail("**Script compilation failed.** " + (_last_compile_error if not _last_compile_error.is_empty() else "Check syntax and Godot API usage."))
	
	var instance: Variant = script.new()
	if not instance or not instance is EditorScript:
		return ToolResult.fail("**Script instantiation failed.** Code must extend EditorScript.")
	
	instance._run()
	
	# === Layer 4: Post-execution snapshot + audit ===
	var snapshot_after: Dictionary = _collect_file_snapshot()
	var audit: Dictionary = _diff_snapshots(snapshot_before, snapshot_after)
	_update_backup_audit(backup_id, audit)
	
	# Post-execution audit: verify all changes are within declared paths
	var violations: Array[String] = []
	for path in audit.created + audit.modified + audit.deleted:
		if path not in file_paths:
			violations.append("- `%s` — not in declared file_paths" % path)
	
	if not violations.is_empty():
		var fail_msg: String = "**Security violations detected after execution.**\n\n"
		fail_msg += "The following file operations affect paths that were not declared:\n"
		fail_msg += "\n".join(violations) + "\n\n"
		fail_msg += "**Declared paths:**\n"
		
		for p in file_paths:
			fail_msg += "- `%s`\n" % p
		
		fail_msg += "\n---\n"
		fail_msg += "**Backup saved for manual rollback.**\n"
		fail_msg += "Backup ID: **`%s`**\n" % backup_id
		return ToolResult.fail(fail_msg)
	
	# Build normal result
	var result_text: String = "**Editor Script executed successfully.**\n\n"
	
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
	
	if audit.created.is_empty() and audit.modified.is_empty() and audit.deleted.is_empty():
		result_text += "*(No file system changes detected.)*\n"
	
	result_text += "---\n"
	result_text += "**Backup saved for manual rollback.**\n"
	result_text += "Backup ID: **`%s`**\n" % backup_id
	
	ToolBox.refresh_editor_filesystem()
	
	var warnings: Array = static_result.get_extra("warnings", [])
	if not warnings.is_empty():
		result_text += "\n**Static Analysis Warnings:**\n"
		for w in warnings:
			result_text += "- %s\n" % w
	
	return ToolResult.ok(result_text)


# ============================================================================
# Layer 1A — Validate Declared Paths
# ============================================================================

func _validate_declared_paths(p_paths: Array) -> ToolResult:
	var blocks: Array[String] = []
	
	for path in p_paths:
		if typeof(path) != TYPE_STRING:
			return ToolResult.fail("'file_paths' must contain only strings.")
		
		if not path.begins_with("res://"):
			blocks.append('Path "%s" must start with "res://".' % path)
			continue
		
		var ext: String = path.get_extension().to_lower()
		if ext not in ALLOWED_EXTENSIONS and not ext.is_empty():
			blocks.append('Path "%s" has unsupported extension ".%s".' % [path, ext])
			continue
		
		for prefix in RESTRICTED_PATH_PATTERNS:
			if path.to_lower().begins_with(prefix):
				blocks.append('Path "%s" is inside restricted zone `%s`.' % [path, prefix])
				break
	
	if not blocks.is_empty():
		var ext_list: String = ""
		for e in ALLOWED_EXTENSIONS:
			ext_list += "- `.%s`\n" % e
		
		var msg: String = "**Invalid file paths declared.**\n\n"
		msg += "\n".join(blocks) + "\n\n"
		msg += "**Allowed file formats:**\n" + ext_list
		msg += "\n**Restricted zones:**\n"
		for r in RESTRICTED_PATH_PATTERNS:
			msg += "- `%s`\n" % r
		
		return ToolResult.fail(msg)
	
	return ToolResult.ok("")


# ============================================================================
# Layer 1C — Verify Code Paths vs Declared Set
# ============================================================================

func _verify_code_paths(p_code: String, p_declared: Array) -> ToolResult:
	var used: Array[String] = []
	
	# Extract all "res://..." string literals from code (double-quoted)
	var dq_pat: RegEx = RegEx.create_from_string('"(res://[^"]*)"')
	for match in dq_pat.search_all(p_code):
		var path: String = match.get_string(1)
		if path not in used:
			used.append(path)
	
	# Single-quoted
	var sq_pat: RegEx = RegEx.create_from_string("'(res://[^']*)'")
	for match in sq_pat.search_all(p_code):
		var path: String = match.get_string(1)
		if path not in used:
			used.append(path)
	
	# Each code path must be in declared set
	var undeclared: Array[String] = []
	for path in used:
		if path not in p_declared:
			undeclared.append(path)
	
	if not undeclared.is_empty():
		var msg: String = "**Code contains undeclared file paths.**\n\n"
		msg += "The following paths appear in code but were not declared in `file_paths`:\n"
		for u in undeclared:
			msg += "- `%s`\n" % u
		msg += "\n**Declared paths:**\n"
		for d in p_declared:
			msg += "- `%s`\n" % d
		msg += "\nDeclare all file paths in the `file_paths` parameter before using them in code."
		return ToolResult.fail(msg)
	
	return ToolResult.ok("")


# ============================================================================
# Layer 1D — Dynamic Path Detection (with symbol tracking)
# ============================================================================

# 在原始代码上构建 {变量名: 字符串值} 映射表。
# 只记录能追溯到字符串字面量赋值的变量（支持变量引用链解析）。
func _build_path_var_table(p_code: String) -> Dictionary:
	var literals: Dictionary = {}
	var refs: Dictionary = {}
	
	var assign_pat := RegEx.create_from_string(
		"(?:var\\s+)?(\\w+)\\s*(?::\\s*[\\w\\.]+\\s*)?(?::=|=(?!=))\\s*(.+)")
	
	for m in assign_pat.search_all(p_code):
		var name: String = m.get_string(1)
		var rhs: String = m.get_string(2).strip_edges()
		
		# 去除行尾注释（简单处理：" #" 模式）
		var hash_pos: int = rhs.find(" #")
		if hash_pos != -1:
			rhs = rhs.substr(0, hash_pos).strip_edges()
		if rhs.is_empty():
			continue
		
		# 字符串字面量 → 直接记录值
		if (rhs.begins_with('"') and rhs.ends_with('"') and rhs.length() >= 2) or \
		   (rhs.begins_with("'") and rhs.ends_with("'") and rhs.length() >= 2):
			literals[name] = rhs.substr(1, rhs.length() - 2)
		# 变量引用（单个标识符）→ 记录引用关系
		elif rhs.is_valid_identifier():
			if not literals.has(name):
				refs[name] = rhs
	
	# 解析引用链（最多 10 轮直至收敛）
	var result: Dictionary = literals.duplicate()
	var changed := true
	var iter := 0
	while changed and iter < 10:
		changed = false
		iter += 1
		for key in refs:
			if not result.has(key):
				var target: String = refs[key]
				if result.has(target):
					result[key] = result[target]
					changed = true
	
	return result


# 检查 API 调用的路径参数是否合法。
# 返回空字符串表示放行，非空字符串为违规描述。
func _check_path_argument(p_arg: String, p_path_vars: Dictionary, p_declared: Array, p_call_name: String) -> String:
	# 1. 字符串字面量 → 必须 res:// 开头且在声明集
	if p_arg.begins_with('"') or p_arg.begins_with("'"):
		var literal: String = p_arg.substr(1, p_arg.length() - 2)
		if not literal.begins_with("res://"):
			return "%s uses non-res:// path `%s` — only project paths are allowed." % [p_call_name, literal]
		if literal not in p_declared:
			return "%s uses path `%s` not in declared file_paths." % [p_call_name, literal]
		return ""
	
	# 2. 变量名 → 查路径变量映射表
	if p_arg.is_valid_identifier():
		if p_path_vars.has(p_arg):
			var resolved_path: String = p_path_vars[p_arg]
			if resolved_path in p_declared:
				return ""  # 合法：变量引用声明的路径
			return "%s uses variable `%s` → `%s` which is not in declared file_paths." % [p_call_name, p_arg, resolved_path]
		return "%s uses variable `%s` with non-literal or unresolvable value — dynamic paths are not allowed." % [p_call_name, p_arg]
	
	# 3. 其他表达式（拼接、函数调用等）
	return "%s uses expression `%s` — only string literals or variables assigned to declared paths are allowed." % [p_call_name, p_arg]


# 检测 FileAccess / ResourceSaver 调用中的动态或未声明路径。
# 与 L1C 互补：L1C 只检查 res:// 字面量，本函数检查变量参数和表达式参数。
func _check_dynamic_api_calls(p_code: String, p_declared: Array) -> ToolResult:
	# 构建 变量→字符串值 映射表（用于追踪变量来源）
	var path_vars: Dictionary = _build_path_var_table(p_code)
	
	var blocks: Array[String] = []
	var seen: Dictionary = {}
	
	# 检测 FileAccess 静态方法的第一个参数
	var fa_pat := RegEx.create_from_string('FileAccess\\.(\\w+)\\s*\\(\\s*([^,\\)]+)')
	for m in fa_pat.search_all(p_code):
		var method: String = m.get_string(1)
		var arg: String = m.get_string(2).strip_edges()
		var dedup_key: String = method + "|" + arg
		if seen.has(dedup_key):
			continue
		seen[dedup_key] = true
		
		var violation: String = _check_path_argument(arg, path_vars, p_declared, "FileAccess.%s()" % method)
		if not violation.is_empty():
			blocks.append(violation)
	
	# 检测 ResourceSaver.save 的第二个参数（路径）
	var rs_pat := RegEx.create_from_string("ResourceSaver\\.save\\s*\\(\\s*[^,]+,\\s*([^,\\)]+)")
	for m in rs_pat.search_all(p_code):
		var arg: String = m.get_string(1).strip_edges()
		var dedup_key: String = "save|" + arg
		if seen.has(dedup_key):
			continue
		seen[dedup_key] = true
		
		var violation: String = _check_path_argument(arg, path_vars, p_declared, "ResourceSaver.save()")
		if not violation.is_empty():
			blocks.append(violation)
	
	if not blocks.is_empty():
		var msg: String = "**Dynamic or undeclared file path detected in API call.**\n\n"
		msg += "All file path arguments must be:\n"
		msg += '- Direct string literals in the declared `file_paths` (e.g. `"res://path/file.gd"`)\n'
		msg += '- Or variables assigned to such literals (e.g. `var p = "res://path/file.gd"`)\n\n'
		msg += "The following violations were detected:\n"
		for b in blocks:
			msg += "- %s\n" % b
		return ToolResult.fail(msg)
	
	return ToolResult.ok("")


# ============================================================================
# L2 Static Analysis — Danger API Checks
# ============================================================================

func _strip_strings_and_comments(p_code: String) -> String:
	var code := p_code
	var dq_pattern: RegEx = RegEx.create_from_string('"[^"]*"')
	var sq_pattern: RegEx = RegEx.create_from_string("'[^']*'")
	code = dq_pattern.sub(code, '""', true)
	code = sq_pattern.sub(code, "''", true)
	var lines := code.split("\n")
	
	for i in lines.size():
		var hash_pos: int = lines[i].find("#")
		if hash_pos != -1:
			lines[i] = lines[i].substr(0, hash_pos)
	
	return "\n".join(lines)


func _build_symbol_table(p_code: String) -> Dictionary:
	var table: Dictionary = {}
	var assign_pattern: RegEx = RegEx.create_from_string(
		"(?:var\\s+)?(\\w+)\\s*(?::\\s*[\\w\\.]+\\s*)?(?::=|=(?!=))\\s*(.+)")
	
	for match in assign_pattern.search_all(p_code):
		var var_name: String = match.get_string(1)
		var rhs: String = match.get_string(2).strip_edges()
		var resolved: String = _resolve_rhs(rhs)
		if not resolved.is_empty():
			table[var_name] = resolved
	
	return table


func _resolve_rhs(p_rhs: String) -> String:
	p_rhs = p_rhs.strip_edges()
	
	var call_match: RegEx = RegEx.create_from_string("^(\\w+)\\.")
	var cm: RegExMatch = call_match.search(p_rhs)
	if cm:
		return cm.get_string(1)
	
	var id_match: RegEx = RegEx.create_from_string("^(\\w+)$")
	var im: RegExMatch = id_match.search(p_rhs)
	if im:
		return im.get_string(1)
	
	return ""


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


func _extract_calls(p_code: String) -> Array[Dictionary]:
	var calls: Array[Dictionary] = []
	var seen: Dictionary = {}
	var call_pattern: RegEx = RegEx.create_from_string("(\\w+|\\))\\.(\\w+)\\s*\\(")
	
	for match in call_pattern.search_all(p_code):
		var obj: String = match.get_string(1)
		var method: String = match.get_string(2)
		var key: String = obj + "." + method
		
		if not seen.has(key):
			seen[key] = true
			calls.append({"object": obj, "method": method})
	
	return calls


func _static_analysis_l2(p_code: String) -> ToolResult:
	var blocks: Array[String] = []
	var warns: Array[String] = []
	
	var clean_code: String = _strip_strings_and_comments(p_code)
	var raw_table: Dictionary = _build_symbol_table(clean_code)
	var symbol_table: Dictionary = _resolve_symbol_table(raw_table)
	var calls: Array[Dictionary] = _extract_calls(clean_code)
	
	for call in calls:
		var obj: String = call["object"]
		var method: String = call["method"]
		var resolved_obj: String = symbol_table.get(obj, obj)
		
		# === Step A: Check DANGEROUS_NETWORK_CLASSES ===
		if resolved_obj in DANGEROUS_NETWORK_CLASSES:
			blocks.append("%s is forbidden — network APIs are not allowed." % resolved_obj)
			continue
		
		# === Step B: Check BLOCKED_CLASSES (any method on high-risk classes) ===
		if resolved_obj in BLOCKED_CLASSES:
			blocks.append("%s is a high-risk class — all method calls are blocked." % resolved_obj)
			continue
		
		# === Step C: Check DANGEROUS_TYPED_CALLS (class + method) ===
		var typed_hit: bool = false
		for rule in DANGEROUS_TYPED_CALLS:
			if resolved_obj == rule["object"] and method == rule["method"]:
				blocks.append(rule["message"])
				typed_hit = true
				break
		if typed_hit:
			continue
		
		# === Step D: Chain call detection ===
		# Object type unresolvable via static analysis — conservative block
		if resolved_obj == ")":
			var chain_hit: bool = false
			for rule in DANGEROUS_TYPED_CALLS:
				if method == rule["method"]:
					blocks.append("Chain call with %s() is forbidden — cannot resolve object type via static analysis." % [method])
					chain_hit = true
					break
			if chain_hit:
				continue
	
	if not blocks.is_empty():
		var msg: String = "**Static analysis blocked execution.**\n\nThe following forbidden patterns were detected:\n"
		for b in blocks:
			msg += "- %s\n" % b
		msg += "\nRewrite the code without these operations."
		return ToolResult.fail(msg)
	
	if not warns.is_empty():
		return ToolResult.ok("", {"warnings": warns})
	
	return ToolResult.ok("")


# ============================================================================
# Code Wrapping & Compilation
# ============================================================================

func _wrap_code(p_code: String) -> String:
	var clean_code: String = p_code.strip_edges()
	if "extends EditorScript" not in clean_code:
		clean_code = "extends EditorScript\n\n" + clean_code
	
	var class_name_regex: RegEx = RegEx.create_from_string("(?m)^class_name\\s+\\w+(?:\\s*#.*)?$")
	clean_code = class_name_regex.sub(clean_code, "", true)
	if not clean_code.begins_with("@tool"):
		clean_code = "@tool\n" + clean_code
	
	return clean_code


func _compile_script(p_code: String) -> GDScript:
	_last_compile_error = ""
	var editor_log: RichTextLabel = EditorConsoleReader.output_label()
	var before_text: String = editor_log.get_parsed_text() if editor_log else ""
	var script: GDScript = GDScript.new()
	script.source_code = p_code
	
	var err: Error = script.reload()
	if err != OK:
		if editor_log:
			var after_text: String = editor_log.get_parsed_text()
			var captured: String = EditorConsoleReader.capture_error_delta(before_text, after_text)
			if not captured.is_empty():
				_last_compile_error = captured
		printerr("[run_editor_script] Compilation error: ", err)
		return null
	
	return script


# ============================================================================
# File System Snapshot & Audit (Layer 4)
# ============================================================================

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
			# 大文件用 mtime 兜底（几乎不会被编辑器脚本修改），其余用内容哈希
			var file: FileAccess = FileAccess.open(full_path, FileAccess.READ)
			if file:
				var size: int = file.get_length()
				file.close()
				if size > MAX_BACKUP_SIZE:
					p_snapshot[full_path] = FileAccess.get_modified_time(full_path)
				else:
					p_snapshot[full_path] = FileAccess.get_md5(full_path)
			else:
				# 打开失败兜底（正常不会发生）
				p_snapshot[full_path] = FileAccess.get_modified_time(full_path)
		
		item = dir.get_next()
	
	dir.list_dir_end()


func _diff_snapshots(p_before: Dictionary, p_after: Dictionary) -> Dictionary:
	var created: Array[String] = []
	var modified: Array[String] = []
	var deleted: Array[String] = []
	
	for path in p_after:
		if not p_before.has(path):
			created.append(path)
		elif p_after[path] != p_before[path]:
			modified.append(path)
	
	for path in p_before:
		if not p_after.has(path):
			deleted.append(path)
	
	return {"created": created, "modified": modified, "deleted": deleted}


# ============================================================================
# Backup & Disk Persistence
# ============================================================================

func _generate_backup_id() -> String:
	var dt: Dictionary = Time.get_datetime_dict_from_system()
	var base: String = "rollback_%04d%02d%02d_%02d%02d%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second]
	var id: String = base
	var counter: int = 1
	# 同秒碰撞防护：目标文件已存在则追加序号，保证目录内唯一
	while FileAccess.file_exists(PluginPaths.BACKUP_DIR + id + ".tres"):
		id = "%s_%02d" % [base, counter]
		counter += 1
	return id


func _save_backup_to_disk(p_backup_id: String, p_code: String, p_file_paths: Array, p_files: Dictionary) -> void:
	var backup := EditorScriptAutoBackup.new()
	backup.backup_id = p_backup_id
	backup.timestamp = Time.get_unix_time_from_system()
	backup.script_code = p_code
	
	# Store declared paths in the backup (for audit/reference)
	for path in p_file_paths:
		if not backup.file_paths.has(path):
			backup.file_paths.append(path)
			backup.file_contents.append(PackedByteArray())
	
	# Store actual file contents (pre-execution snapshot)
	for path in p_files:
		var idx: int = backup.file_paths.find(path)
		if idx != -1:
			backup.file_contents[idx] = p_files[path]
		else:
			backup.add_file(path, p_files[path])
	
	EditorScriptAutoBackup.ensure_backup_dir_exists()
	var save_path: String = PluginPaths.BACKUP_DIR + p_backup_id + ".tres"
	var err: Error = ResourceSaver.save(backup, save_path)
	if err != OK:
		AIChatLogger.error("[run_editor_script] Failed to save backup: " + str(err))


func _update_backup_audit(p_backup_id: String, p_audit: Dictionary) -> void:
	var backup_path: String = PluginPaths.BACKUP_DIR + p_backup_id + ".tres"
	if not ResourceLoader.exists(backup_path):
		return
	
	var backup: EditorScriptAutoBackup = ResourceLoader.load(backup_path, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
	if not backup:
		return
	
	backup.audit_created = p_audit.get("created", [])
	backup.audit_modified = p_audit.get("modified", [])
	backup.audit_deleted = p_audit.get("deleted", [])
	ResourceSaver.save(backup, backup_path)


func _backup_target_files(p_targets: Dictionary) -> Dictionary:
	var backup: Dictionary = {}
	for category in ["write", "delete"]:
		for path in p_targets.get(category, []):
			if backup.has(path):
				continue
			if not FileAccess.file_exists(path):
				continue
			var file: FileAccess = FileAccess.open(path, FileAccess.READ)
			if not file:
				continue
			var size: int = file.get_length()
			if size > MAX_BACKUP_SIZE:
				file.close()
				continue
			backup[path] = file.get_buffer(size)
			file.close()
	return backup
