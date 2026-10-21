@tool
extends AiTool

## Runs an existing EditorScript file inside the editor.
## Safety model: caller declares `script_path` (the script to run) and `file_paths`
## (the only paths the script may touch) → script path is validated → source is read
## from disk → static analysis runs on that exact source (danger APIs + path
## consistency) → executed → file system audited.
## The script already exists on disk, so the analysed text and the executed text
## are byte-identical — no wrapping, no rewriting.

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

## Executable scripts must be GDScript (EditorScript is GDScript-only).
const SCRIPT_EXTENSION: String = "gd"

## Expected script skeleton, echoed back when a structure check fails.
const EXPECTED_SCRIPT_TEMPLATE: String = "@tool\nextends EditorScript\n\n\nfunc _run() -> void:\n\tpass\n"

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

# --- Constants ---

const EditorConsoleReader := preload("res://addons/godot_ai_chat/scripts/helper/editor_console_reader.gd")

# --- Private Vars ---

# Source read from `script_path` — shared by the structure checks, the Layer 1
# static analysis and the Layer 3 compilation.
var _script_source: String = ""

# Stores the exact compiler error text captured from EditorLog.
var _last_compile_error: String = ""

# ============================================================================
# Built-in Functions
# ============================================================================

func _init() -> void:
	tool_name = "run_editor_script"
	tool_description = "Runs an existing `EditorScript` file inside the Godot editor, This tool is disabled by default."

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"script_path": {
				"type": "string",
				"description": "Path of an existing script file to run. Create the file first, then run it here."
			},
			"file_paths": {
				"type": "array",
				"items": {"type": "string"},
				"description": "List of file paths this script will operate on. All \"res://\" paths in the script must appear in this list."
			}
		},
		"required": ["script_path", "file_paths"]
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
	
	var script_path: String = p_args.get("script_path", "")
	var file_paths: Array = p_args.get("file_paths", [])
	
	if script_path.is_empty():
		return ToolResult.fail("'script_path' parameter is required.")
	if file_paths.is_empty():
		return ToolResult.fail("'file_paths' parameter is required — declare at least one file path.")
	
	# === Layer 1A: Validate declared paths (pure parameter check) ===
	var path_validation: ToolResult = _validate_declared_paths(file_paths)
	if path_validation.is_fail():
		return path_validation
	
	# === Layer 1B: Validate script path & load its source from disk ===
	var script_load: ToolResult = _load_script(script_path)
	if script_load.is_fail():
		return script_load
	var code: String = _script_source
	
	# === Layer 1C: Static analysis (danger APIs) ===
	var static_result: ToolResult = _static_analysis(code)
	if static_result.is_fail():
		return static_result
	
	# === Layer 1D: Verify code paths match declared set ===
	var verify_result: ToolResult = _verify_code_paths(code, file_paths)
	if verify_result.is_fail():
		return verify_result
	
	# === Layer 1E: Check for non-literal API calls (dynamic paths) ===
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
	
	var snapshot_before: Dictionary = _collect_file_snapshot(file_paths)
	
	# === Layer 3: Compile and execute ===
	var script: GDScript = _compile_script(code)
	if not script:
		return ToolResult.fail("**Script compilation failed.** " + (_last_compile_error if not _last_compile_error.is_empty() else "Check syntax and Godot API usage."))
	
	var instance: Variant = script.new()
	if not instance or not instance is EditorScript:
		return ToolResult.fail("**Script instantiation failed.** Code must extend EditorScript.")
	
	instance._run()
	
	# === Layer 4: Post-execution snapshot + audit ===
	var snapshot_after: Dictionary = _collect_file_snapshot(file_paths)
	var audit: Dictionary = _diff_snapshots(snapshot_before, snapshot_after)
	_update_backup_audit(backup_id, audit)
	
	# Post-execution audit: verify all changes are within declared paths
	var violations: Array[String] = []
	for path in audit.created + audit.modified + audit.deleted:
		if path not in file_paths:
			violations.append("- `%s` — not in declared file_paths" % path)
	
	if not violations.is_empty():
		var fail_msg: String = "**Security violations detected after execution.**\n\n"
		fail_msg += "Executed script: `%s`\n\n" % script_path
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
	result_text += "Script: `%s`\n\n" % script_path
	
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
# Layer 1B — Script Path Validation & Source Loading
# ============================================================================

# 校验 script_path 形态并从磁盘读入源码（源码写入 _script_source）。
# 脚本必须先落盘，工具不接受内联代码，也不对脚本做任何改写。
func _load_script(p_script_path: String) -> ToolResult:
	_script_source = ""
	
	var shape_err: String = _validate_script_path(p_script_path)
	if not shape_err.is_empty():
		return ToolResult.fail(shape_err)
	
	if not FileAccess.file_exists(p_script_path):
		return ToolResult.fail(
			"**Script not found:** `%s`\n\n"
			% p_script_path
			+ "Write the script file first (e.g. with the `create_script` tool), then run it here."
		)
	
	var file: FileAccess = FileAccess.open(p_script_path, FileAccess.READ)
	if not file:
		return ToolResult.fail(
			"**Cannot read script** `%s`: %s" % [p_script_path, error_string(FileAccess.get_open_error())]
		)
	_script_source = file.get_as_text()
	file.close()
	
	if _script_source.strip_edges().is_empty():
		return ToolResult.fail("**Script is empty:** `%s`" % p_script_path)
	
	var structure_err: String = _validate_script_structure(p_script_path, _script_source)
	if not structure_err.is_empty():
		return ToolResult.fail(structure_err)
	
	return ToolResult.ok("")

# 校验脚本路径形态：res:// 前缀、.gd 扩展名、不在受限区。
func _validate_script_path(p_path: String) -> String:
	if not p_path.begins_with("res://"):
		return "**Invalid `script_path`:** `%s` must start with \"res://\"." % p_path
	
	if p_path.get_extension().to_lower() != SCRIPT_EXTENSION:
		return "**Invalid `script_path`:** `%s` must be a GDScript file (.gd)." % p_path
	
	for prefix in RESTRICTED_PATH_PATTERNS:
		if p_path.to_lower().begins_with(prefix):
			return "**Invalid `script_path`:** `%s` is inside restricted zone `%s` — scripts located there cannot be executed." % [p_path, prefix]
	
	return ""

# 校验脚本结构：必须 @tool + extends EditorScript + func _run()，且不得声明 class_name。
# 判定基于分词器 token 流，字符串/注释中的同名文本不会误判。
# 返回空字符串表示合法，否则返回逐项列出缺失/违规部分的说明。
func _validate_script_structure(p_script_path: String, p_code: String) -> String:
	var tokens := GDScriptTokenizer.tokenize(p_code)
	
	var has_tool_annotation: bool = false
	var has_class_name: bool = false
	var extends_editor_script: bool = false
	var has_run_method: bool = false
	
	for i in tokens.size():
		var t: GDScriptTokenizer.Token = tokens[i]
		
		if t.type == GDScriptTokenizer.TokenType.IDENTIFIER and t.value == "@tool":
			has_tool_annotation = true
		elif t.type == GDScriptTokenizer.TokenType.KEYWORD and t.value == "class_name":
			has_class_name = true
		elif t.type == GDScriptTokenizer.TokenType.KEYWORD and t.value == "extends":
			var base_token: GDScriptTokenizer.Token = _next_meaningful_token(tokens, i)
			if base_token != null and base_token.value == "EditorScript":
				extends_editor_script = true
		elif t.type == GDScriptTokenizer.TokenType.KEYWORD and t.value == "func":
			var func_token: GDScriptTokenizer.Token = _next_meaningful_token(tokens, i)
			if func_token != null and func_token.value == "_run":
				has_run_method = true
	
	var problems: Array[String] = []
	
	if not extends_editor_script:
		problems.append("Missing `extends EditorScript` — the base script must be EditorScript.")
	if not has_tool_annotation:
		problems.append("Missing the `@tool` annotation — EditorScript must be in tool mode.")
	if not has_run_method:
		problems.append("Missing `func _run()` — this is the entry point the editor executes.")
	if has_class_name:
		problems.append("`class_name` is not allowed — the script is compiled as an anonymous GDScript, and a global class name would collide with the project's class registry.")
	
	if problems.is_empty():
		return ""
	
	var msg: String = "**Invalid editor script:** `%s` cannot be executed.\n\n" % p_script_path
	msg += "**Problems found:**\n"
	for p in problems:
		msg += "- %s\n" % p
	msg += "\n**Expected script skeleton:**\n```gdscript\n"
	msg += EXPECTED_SCRIPT_TEMPLATE
	msg += "```\n"
	msg += "\nFix the script file with the script tools, then run this tool again."
	return msg

# 返回 p_index 之后第一个非空白/非换行/非注释 token，没有则返回 null。
func _next_meaningful_token(p_tokens: Array, p_index: int) -> GDScriptTokenizer.Token:
	for i in range(p_index + 1, p_tokens.size()):
		var t: GDScriptTokenizer.Token = p_tokens[i]
		if t.type == GDScriptTokenizer.TokenType.WHITESPACE \
		or t.type == GDScriptTokenizer.TokenType.NEWLINE \
		or t.type == GDScriptTokenizer.TokenType.COMMENT:
			continue
		return t
	return null

# ============================================================================
# Layer 1D — Verify Code Paths vs Declared Set
# ============================================================================

func _verify_code_paths(p_code: String, p_declared: Array) -> ToolResult:
	var used: Array[String] = []
	
	# 使用分词器提取所有 res:// 字符串字面量
	# （正确处理转义引号 / 多行字符串 / raw 字符串，避免字符串内误报）
	for path in GDScriptTokenizer.extract_res_paths(p_code):
		if path not in used:
			used.append(path)
	
	# 每个代码路径必须声明
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
# Layer 1E — Dynamic Path Detection (with symbol tracking)
# ============================================================================

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
# 与 L1D 互补：L1D 只检查 res:// 字面量，本函数检查变量参数和表达式参数。
func _check_dynamic_api_calls(p_code: String, p_declared: Array) -> ToolResult:
	# 变量 → 字符串字面量值 映射（由分词器构建，支持引用链解析）
	var path_vars: Dictionary = GDScriptTokenizer.build_path_var_table(p_code)
	
	var blocks: Array[String] = []
	var seen: Dictionary = {}
	
	# 遍历分词器提取的调用列表，检查 FileAccess / ResourceSaver 的路径参数
	for call in GDScriptTokenizer.extract_calls(p_code):
		var obj: String = call["object"]
		var method: String = call["method"]
		var args: Array = call["args"]
		
		# FileAccess 静态方法的第一个参数是路径
		if obj == "FileAccess" and not args.is_empty():
			var arg: String = args[0]
			var dedup_key: String = method + "|" + arg
			if seen.has(dedup_key):
				continue
			seen[dedup_key] = true
			
			var violation: String = _check_path_argument(arg, path_vars, p_declared, "FileAccess.%s()" % method)
			if not violation.is_empty():
				blocks.append(violation)
		
		# ResourceSaver.save 的第二个参数是路径
		elif obj == "ResourceSaver" and method == "save" and args.size() >= 2:
			var arg: String = args[1]
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
# Layer 1C Static Analysis — Danger API Checks
# ============================================================================

func _static_analysis(p_code: String) -> ToolResult:
	var blocks: Array[String] = []
	var warns: Array[String] = []
	
	# 符号表 + 调用列表由分词器提供（token 流级，天然忽略字符串/注释）
	var symbol_table: Dictionary = GDScriptTokenizer.build_symbol_table(p_code)
	var calls: Array[Dictionary] = GDScriptTokenizer.extract_calls(p_code)
	
	var seen: Dictionary = {}
	for call in calls:
		var obj: String = call["object"]
		var method: String = call["method"]
		var key: String = obj + "." + method
		if seen.has(key):
			continue
		seen[key] = true
		
		var resolved_obj: String = symbol_table.get(obj, obj)
		
		# === Step A: 危险网络类 ===
		if resolved_obj in DANGEROUS_NETWORK_CLASSES:
			blocks.append("%s is forbidden — network APIs are not allowed." % resolved_obj)
			continue
		
		# === Step B: 高危类（任何方法都禁止） ===
		if resolved_obj in BLOCKED_CLASSES:
			blocks.append("%s is a high-risk class — all method calls are blocked." % resolved_obj)
			continue
		
		# === Step C: 指定类 + 方法 ===
		var typed_hit: bool = false
		for rule in DANGEROUS_TYPED_CALLS:
			if resolved_obj == rule["object"] and method == rule["method"]:
				blocks.append(rule["message"])
				typed_hit = true
				break
		if typed_hit:
			continue
		
		# === Step D: 链式调用（对象类型无法静态解析，保守拦截） ===
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
# Code Compilation
# ============================================================================

# 逐字编译磁盘上的脚本源码——不注入 @tool、不剥 class_name、不做任何改写，
# 保证"被静态分析的文本"与"被执行的文本"是同一份。
# 编译错误通过 EditorLog 的 before/after 增量捕获，交由调用方回传给 AI。
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

func _collect_file_snapshot(p_declared: Array = []) -> Dictionary:
	var snapshot: Dictionary = {}
	_collect_files_recursive("res://", snapshot, p_declared)
	return snapshot

# 受限区目录剪枝：这些目录编辑器脚本永远无法声明/写入（Layer 1A 拒绝），
# 审计快照无需覆盖，避免全项目扫描时计入（addons 等往往很大）。
func _is_restricted_dir(p_path: String) -> bool:
	var normalized: String = p_path.to_lower().trim_suffix("/") + "/"
	for prefix in RESTRICTED_PATH_PATTERNS:
		if normalized.begins_with(prefix):
			return true
	return false

func _collect_files_recursive(p_dir: String, p_snapshot: Dictionary, p_declared: Array) -> void:
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
			# 受限区目录剪枝（addons / rollback_files / android 等）
			if _is_restricted_dir(full_path):
				item = dir.get_next()
				continue
			_collect_files_recursive(full_path + "/", p_snapshot, p_declared)
		else:
			# .import 是 Godot 导入缓存元数据，编辑器脚本不可能写入，跳过
			if full_path.ends_with(".import"):
				item = dir.get_next()
				continue
			
			if full_path in p_declared:
				# 声明路径：内容级精确快照（md5，数量少成本低）
				var file: FileAccess = FileAccess.open(full_path, FileAccess.READ)
				if file:
					var size: int = file.get_length()
					file.close()
					if size > MAX_BACKUP_SIZE:
						p_snapshot[full_path] = FileAccess.get_modified_time(full_path)
					else:
						p_snapshot[full_path] = FileAccess.get_md5(full_path)
				else:
					p_snapshot[full_path] = FileAccess.get_modified_time(full_path)
			else:
				# 非声明路径：mtime + size 粗粒度（越界检测用，不读内容）
				var file2: FileAccess = FileAccess.open(full_path, FileAccess.READ)
				var fsize: int = 0
				if file2:
					fsize = file2.get_length()
					file2.close()
				p_snapshot[full_path] = {
					"mtime": FileAccess.get_modified_time(full_path),
					"size": fsize,
				}
		
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
