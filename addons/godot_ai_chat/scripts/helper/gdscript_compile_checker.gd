extends RefCounted

# GDScript 静态编译检查
#
# 用途：给定一份尚未落盘的 .gd 源码，在内存里编译一次并回报编译错误，
# 让写文件的工具在落盘前就拒绝「会引入编译错误」的改动。
#
# 机制：GDScript.new() + source_code + reload()——编译的是匿名副本，
# 不写磁盘、不替换项目里已加载的脚本实例。reload() 只返回 Error 码，
# 错误文本从编辑器 Output 面板的增量中抓取（与 run_editor_script 同一机制）。
#
# class_name 的处理：
# 匿名副本的 class_name 声明不会注册到全局类表，直接编译会出现两类假错误：
# - 类名已注册 → "hides a global script class"；
# - 类名未注册 → 自引用变成「标识符/类型找不到」。
# 因此声明行一律留空（行数不变，错误行号仍准确），再把「本类名解析不到」
# 这类派生噪声剔除；真正的重复类名由注册表显式判定并拦下。
# 剔除数量会在通过消息里披露，便于判断这次检查的覆盖边界。
#
# 其它已知边界：
# - 只覆盖 Error 级别，不产出 warning（unused_variable / shadowed_* 等属于编辑器诊断）；
# - 抓不到错误详情时只回报 Error 码，绝不把「读不到详情」当成「编译通过」。


# --- Constants ---

const GDScriptTokenizer := preload("res://addons/godot_ai_chat/scripts/helper/gdscript_tokenizer.gd")
const EditorConsoleReader := preload("res://addons/godot_ai_chat/scripts/helper/editor_console_reader.gd")

# ProjectSettings.get_global_class_list() 条目中的键名
const KEY_CLASS: String = "class"
const KEY_PATH: String = "path"

# 「本类名在匿名副本里解析不到」的引擎措辞片段（小写比较，命中任一即视为派生噪声）
# 4.8 实测：
#   Identifier "X" not declared in the current scope.
#   Could not find type "X" in the current scope.
const UNRESOLVED_MARKERS: Array[String] = [
	"not declared",
	"not found",
	"not defined",
	"not exist",
	"could not find",
	"cannot find",
	"unknown identifier",
]


# --- Static Vars ---

# 匿名脚本在错误信息里的伪路径前缀（gdscript://<hash>.gd:），清洗成 "line "
static var _anon_path_regex: RegEx = null


# --- Public Functions ---

# 编译检查一份 GDScript 源码
# [param p_code]: 待检查源码（LF 换行，即将写入文件的内容）
# [param p_target_path]: 该源码将要写入的 res:// 路径，用于 class_name 归属判定
static func check(p_code: String, p_target_path: String) -> Outcome:
	if p_code.strip_edges().is_empty():
		return Outcome.new(false, true, "", 0)
	
	var source: SourceText = _prepare_source(p_code, p_target_path)
	if not source.blocking_error.is_empty():
		return Outcome.new(true, false, source.blocking_error, 0)
	
	# 编译前的面板快照：reload() 只把错误写进 Output 面板，没有别的读取途径
	var editor_log: RichTextLabel = EditorConsoleReader.output_label()
	var before_text: String = editor_log.get_parsed_text() if editor_log != null else ""
	
	var script := GDScript.new()
	script.source_code = source.code
	var err: Error = script.reload()
	
	if err == OK:
		return Outcome.new(true, true, "", 0)
	
	var detail: String = ""
	if editor_log != null:
		var delta: String = EditorConsoleReader.capture_error_delta(before_text, editor_log.get_parsed_text())
		detail = _tidy_error_text(delta)
	
	# 声明行被留空后，本类名在匿名副本里无法解析（真实环境中 class_name 是生效的），
	# 这类派生噪声要剔除，否则「新类名 + 自引用」「改名 class_name」都会被误判为失败。
	# 只在确实抓到详情时才据此判通过：读不到详情仍按失败处理，绝不假装通过。
	var ignored_noise: int = 0
	if not source.blind_class_name.is_empty() and not detail.is_empty():
		var kept: PackedStringArray = _drop_self_type_noise(detail, source.blind_class_name)
		ignored_noise = detail.split("\n").size() - kept.size()
		detail = "\n".join(kept)
		if detail.is_empty():
			return Outcome.new(true, true, "", ignored_noise)
	
	if detail.is_empty():
		detail = "(the editor's Output panel could not be read, so no error details are available — check it manually)"
	
	return Outcome.new(true, false, "%s\n(error code: %s)" % [detail, error_string(err)], ignored_noise)


# 生成「编译检查未通过」的失败文案（供写文件的工具直接返回）
# [param p_outcome]: check() 的返回值
# [param p_path]: 目标文件路径
# [param p_action]: 被拒绝的动作，用于措辞（"created" / "modified" 等）
static func format_failure(p_outcome: Outcome, p_path: String, p_action: String) -> String:
	var msg: String = "**GDScript compile check failed — the file was NOT %s.**\n\n" % p_action
	msg += "Target: `%s`\n\n" % p_path
	msg += "Errors found in the code you submitted (line numbers refer to that content):\n"
	msg += "```\n%s\n```\n\n" % p_outcome.error_detail
	msg += "Nothing was written to disk: the check compiles an in-memory copy of your code, so existing files are untouched and the project was not affected.\n\n"
	msg += "Fix the errors and call this tool again. If you are mid-refactor (the script is temporarily incomplete) or it `preload`s a file that does not exist yet, pass `skip_compile_check = true` to write anyway."
	return msg


# 生成「编译检查通过」的简短说明（供成功消息追加）
static func format_pass_note(p_outcome: Outcome) -> String:
	if not p_outcome.is_checked:
		return "Compile check: skipped (empty content)."
	if p_outcome.ignored_noise > 0:
		return "Compile check: passed (ignored %d error(s) about the script's own `class_name`, which an anonymous copy cannot resolve)." % p_outcome.ignored_noise
	return "Compile check: passed."


# --- Private Functions ---

# 预处理源码：判定 class_name 归属，冲突则拦下，否则留空声明行
static func _prepare_source(p_code: String, p_target_path: String) -> SourceText:
	var tokens := GDScriptTokenizer.tokenize(p_code)
	var class_name_decl: String = ""
	var class_name_line: int = 0
	
	for i in tokens.size():
		var t: GDScriptTokenizer.Token = tokens[i]
		if t.type != GDScriptTokenizer.TokenType.KEYWORD or t.value != "class_name":
			continue
		var name_token: GDScriptTokenizer.Token = _next_code_token(tokens, i)
		if name_token != null:
			class_name_decl = name_token.value
			class_name_line = t.line
		break
	
	if class_name_decl.is_empty():
		return SourceText.new(p_code, "", "")
	
	# 注册表指向另一个真实存在的文件 → 真正的类名冲突，直接拦下
	# （声明行被留空后编译器不会再报 hides，所以这件事必须在这里判）
	var registered_path: String = _global_class_path(class_name_decl)
	if not registered_path.is_empty() and registered_path != p_target_path and FileAccess.file_exists(registered_path):
		return SourceText.new(
			"",
			"`class_name %s` is already used by `%s`. A global class name must be unique — pick another name." % [class_name_decl, registered_path],
			""
		)
	
	# 声明一律留空：行数不变，错误行号仍然对应提交内容；
	# 自引用因此产生的假错误由 _drop_self_type_noise 剔除
	return SourceText.new(_blank_line(p_code, class_name_line), "", class_name_decl)


# 在全局类注册表里查类名对应的脚本路径；查不到（或非编辑器环境）返回空串
static func _global_class_path(p_name: String) -> String:
	if not Engine.is_editor_hint():
		return ""
	
	for entry: Dictionary in ProjectSettings.get_global_class_list():
		if String(entry[KEY_CLASS]) == p_name:
			return String(entry[KEY_PATH])
	
	return ""


# 返回 p_index 之后的第一个代码 token（跳过空白/换行/注释），没有则返回 null
static func _next_code_token(p_tokens: Array, p_index: int) -> GDScriptTokenizer.Token:
	for i in range(p_index + 1, p_tokens.size()):
		var t: GDScriptTokenizer.Token = p_tokens[i]
		if t.type == GDScriptTokenizer.TokenType.WHITESPACE \
		or t.type == GDScriptTokenizer.TokenType.NEWLINE \
		or t.type == GDScriptTokenizer.TokenType.COMMENT:
			continue
		return t
	
	return null


# 把指定行（1-based）整行留空，行数保持不变
static func _blank_line(p_code: String, p_line: int) -> String:
	var lines: PackedStringArray = p_code.split("\n")
	if p_line < 1 or p_line > lines.size():
		return p_code
	lines[p_line - 1] = ""
	return "\n".join(lines)


# 剔除「抹掉 class_name 声明后，本类名无法解析」这类派生噪声，返回剩余行
static func _drop_self_type_noise(p_detail: String, p_name: String) -> PackedStringArray:
	var kept: PackedStringArray = PackedStringArray()
	
	for line: String in p_detail.split("\n"):
		var trimmed: String = line.strip_edges()
		if trimmed.is_empty():
			continue
		if _is_self_type_noise(trimmed, p_name):
			continue
		kept.append(trimmed)
	
	return kept


# 判断某行错误是否只是「本类名找不到」的派生产物：
# 必须同时满足「类名以完整词形出现」+「含解析失败的措辞」，避免类名互为词缀时误杀真错误
static func _is_self_type_noise(p_line: String, p_name: String) -> bool:
	if not _mentions_as_word(p_line, p_name):
		return false
	
	var lowered: String = p_line.to_lower()
	for marker: String in UNRESOLVED_MARKERS:
		if lowered.contains(marker):
			return true
	
	return false


# 类名是否以完整标识符形态出现在文本里（前后不是标识符字符）
static func _mentions_as_word(p_line: String, p_name: String) -> bool:
	var start: int = p_line.find(p_name)
	
	while start != -1:
		var end: int = start + p_name.length()
		var before_ok: bool = start == 0 or not _is_ident_char(p_line[start - 1])
		var after_ok: bool = end >= p_line.length() or not _is_ident_char(p_line[end])
		if before_ok and after_ok:
			return true
		start = p_line.find(p_name, start + 1)
	
	return false


# 是否为标识符可用字符
static func _is_ident_char(p_ch: String) -> bool:
	return p_ch == "_" \
	or (p_ch >= "0" and p_ch <= "9") \
	or (p_ch >= "a" and p_ch <= "z") \
	or (p_ch >= "A" and p_ch <= "Z") \
	or p_ch.unicode_at(0) > 127


# 清理抓取到的错误文本：匿名脚本伪路径改成 "line N"，去掉行首孤立冒号，折叠空行
static func _tidy_error_text(p_text: String) -> String:
	if _anon_path_regex == null:
		_anon_path_regex = RegEx.create_from_string("gdscript://-?\\d+\\.gd:")
	
	var out: PackedStringArray = PackedStringArray()
	
	for raw_line: String in p_text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.is_empty():
			continue
		line = _anon_path_regex.sub(line, "line ", true)
		line = line.replace("<anonymous>", "").lstrip(": ")
		if line.is_empty():
			continue
		out.append(line)
	
	return "\n".join(out)


# --- Inner Classes ---

# 编译检查结果
class Outcome:
	# 是否真的执行了编译（内容为空等无需检查的情况为 false）
	var is_checked: bool
	# 是否通过
	var is_passed: bool
	# 未通过时的错误详情（可能为空：表示检查执行了但读不到详情）
	var error_detail: String
	# 因「本类名在匿名副本里无法解析」而被忽略的报错行数（用于在通过时披露检查边界）
	var ignored_noise: int
	
	
	func _init(p_is_checked: bool, p_is_passed: bool, p_error_detail: String, p_ignored_noise: int) -> void:
		is_checked = p_is_checked
		is_passed = p_is_passed
		error_detail = p_error_detail
		ignored_noise = p_ignored_noise


# 预处理后的源码
class SourceText:
	var code: String
	# 非空表示在编译前就已判定失败（如类名冲突）
	var blocking_error: String
	# 被留空的 class_name（空串表示没有留空）；用于剔除自引用噪声
	var blind_class_name: String
	
	
	func _init(p_code: String, p_blocking_error: String, p_blind_class_name: String) -> void:
		code = p_code
		blocking_error = p_blocking_error
		blind_class_name = p_blind_class_name
