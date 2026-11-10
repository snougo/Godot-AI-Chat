extends AiTool

# 统一搜索工具：一个入口，两种模式。
#
# mode = "text"（默认）：
#   在指定文件夹的文本文件中查找某段内容（符号、字符串、资源路径等）的所有出现位置。
#   返回 文件路径 + 行号 + 该行内容，用于引用定位、重构影响分析、代码审计。
#   - 大小写敏感：贴合"已知拼写准确定位"的调用前提；大小写不符由零命中时的宽松扫描提示兜底。
#   - 边界检查只作用于搜索串首/尾本身是标识符字符的那一侧：
#     `get_node(`、`.new(`、`"res://a.gd"` 这类以符号收尾的片段，不会因为前一个字符是标识符字符被误判。
#   - 下划线相邻的命中（`get_node` 之于 `get_node_or_null`）归为 `ext` 命中：
#     默认汇报但显式标注，既不吞掉前缀类搜索，也不会被当成精确引用。
#   - 行内容按 MAX_LINE_CHARS 截断，超出以 "…" 结尾。
#     行内容是**单行视图**：配合 `ext` / `comment` / `string` 标记可以判断"这一行是什么性质"，
#     但跨行上下文（该行是否在函数体内、是否落在块注释中间）仍需 read_file 确认。
#
# mode = "doc"：
#   搜索本地 Godot 离线文档（未指定 path 时用 res://godot_doc）。
#   优先匹配文档标题（文件名），标题零命中的关键词才落到正文匹配。
#   只扫文档格式（md / txt），不扫脚本等格式。
#   只返回文档路径，不返回行号与内容 —— 拿到路径后必须 read_file 才能判断内容是否相关。
#
# 所有降级路径（文件过大跳过 / 二进制跳过 / 扩展名被拒 / 文件数触顶 / 结果数触顶 /
# 宽松扫描受限 / 文档正文扫描受限）都会在输出首行以 [PARTIAL] 标注，
# 避免 AI 把"没扫到的范围"误判成"没有引用"。


# --- Constants ---

# 允许搜索的扩展名白名单（仅文本格式）。extensions 参数只能取此列表的子集。
# 场景（tscn）与资源（tres）刻意排除：它们的行内容几乎不含有效信息，
# 且 read_file 已提供结构摘要，按行检索只会产生噪音。
const ALLOWED_EXTENSIONS: Array[String] = ["gd", "gdshader", "glsl", "cfg", "md"]

# 默认搜索的扩展名（未传 extensions 或所传扩展名全部无效时使用）
const DEFAULT_EXTENSIONS: Array[String] = ["gd"]

# 单个文件大小上限（超过此大小的文件跳过，防止大文件卡死）
const MAX_FILE_SIZE: int = 4096 * 4096

# 最大搜索文件数（防止文件夹过大导致超时）
const MAX_FILES: int = 2000

# 命中行数上限（触顶时输出告警，提示缩小搜索范围）
# 因为每行都附带行内容，上限比纯行号时代更低，避免单次输出撑爆上下文
const MAX_RESULTS: int = 300

# 单行内容展示上限（超出以 "…" 结尾）
const MAX_LINE_CHARS: int = 200

# 遍历时直接跳过的目录：缓存 / 版本控制 / 备份 / 第三方构建产物
# 否则排序后靠前的缓存文件会吃掉 MAX_FILES 预算，导致真正的代码没被扫到
const PRUNED_DIRS: Array[String] = [".godot", ".git", ".import", ".svn", "node_modules", "rollback_files",]

# 宽松扫描的文件数上限（只在主查询零命中时触发）
const RELAXED_SCAN_MAX_FILES: int = 200

# 边界判定结果
const BOUNDARY_FAIL: int = 0
const BOUNDARY_STRICT: int = 1
const BOUNDARY_EXTENDED: int = 2

# 命中行的上下文标记（位标记）
const CTX_NONE: int = 0
const CTX_COMMENT: int = 1
const CTX_STRING: int = 2

# 搜索模式
const MODE_TEXT: String = "text"
const MODE_DOC: String = "doc"

# 本地 Godot 离线文档根目录（mode=doc 且未指定 path 时使用）
const LOCAL_DOC_PATH: String = "res://godot_doc"

# 离线文档转换工具仓库地址（文档缺失时提示用户使用）
const DOC_CONVERSION_REPO_URL: String = "https://github.com/snougo/Godot-Doc-Conversion-Utils"

# 文档模式参与搜索的扩展名：只扫文档格式，不扫脚本等格式
const DOC_EXTENSIONS: Array[String] = ["md", "txt"]

# 单个关键词最多展示的标题匹配条数
const MAX_TITLE_RESULTS_PER_KEYWORD: int = 20

# 文档正文扫描的文件数上限（标题零命中时才触发，防止 classes/ 上千文档全量扫描）
const DOC_CONTENT_MAX_FILES: int = 300

# 文档正文匹配的文件数上限（触顶时输出告警）
const DOC_CONTENT_MAX_RESULTS: int = 100


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "search_in_files"
	tool_description = "Searches local content: a project folder's text files (mode=\"text\", returns paths + line numbers + line contents), or the local Godot offline docs (mode=\"doc\", returns document paths only)."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"search": {
				"type": "string",
				"description": "mode=\"text\": exact symbol or snippet to find. Case-sensitive, single line; hits inside longer identifiers are tagged `ext`. mode=\"doc\": one or more keywords, case-insensitive, separated by spaces or commas; each keyword is searched separately."
			},
			"path": {
				"type": "string",
				"description": "The full path of the folder to search. Scanned recursively. Required when mode=\"text\". Defaults to `res://godot_doc` when mode=\"doc\"."
			},
			"mode": {
				"type": "string",
				"enum": ["text", "doc"],
				"description": "What to search. \"text\" (default): contents of text files in `path`. \"doc\": the local Godot offline documentation — document titles first, then document bodies."
			},
			"extensions": {
				"type": "array",
				"items": { "type": "string" },
				"description": "mode=\"text\" only. Text-based file extensions to scan, support: gd, gdshader, glsl, cfg, md. Default: gd. Ignored in mode=\"doc\"."
			}
		},
		"required": ["search"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var search: String = str(p_args.get("search", ""))
	if search.is_empty():
		return ToolResult.fail("Missing parameter: search")
	
	var mode: String = str(p_args.get("mode", MODE_TEXT)).strip_edges().to_lower()
	if mode == MODE_DOC:
		return _execute_doc_mode(p_args, search)
	if mode != MODE_TEXT:
		return ToolResult.fail("Error: Unsupported mode `%s`. Use \"text\" or \"doc\"." % mode)
	
	return _execute_text_mode(p_args, search)


# --- Private Functions: Dispatch ---

# mode = "text"：在指定文件夹的文本文件中检索内容
func _execute_text_mode(p_args: Dictionary, p_search: String) -> ToolResult:
	var path: String = str(p_args.get("path", "")).strip_edges()
	
	# --- 参数校验 ---
	if path.is_empty():
		return ToolResult.fail("Missing parameter: path (required when mode=\"text\").")
	if not path.begins_with("res://"):
		return ToolResult.fail("Error: Path must start with 'res://'.")
	if ".." in path:
		return ToolResult.fail("Error: Path traversal ('..') is not allowed.")
	if not DirAccess.dir_exists_absolute(path):
		return ToolResult.fail("Error: Folder not found: " + path)
	# schema 声明 single-line only，这里必须实际兜住，否则跨行 search 会命中但行号只记起始行
	if "\n" in p_search or "\r" in p_search:
		return ToolResult.fail("Error: `search` must be a single line in mode=\"text\".")
	
	var ext_result: Dictionary = _resolve_extensions(p_args.get("extensions"))
	var extensions: Array[String] = ext_result["extensions"]
	var rejected_exts: Array[String] = ext_result["rejected"]
	
	# --- 收集文件（多收 1 个用于判断是否触顶）---
	var all_files: Array[String] = []
	_collect_files(path, extensions, all_files, MAX_FILES + 1)
	# 排序：保证同一查询两次返回顺序一致，便于前后比对
	all_files.sort()
	
	# 零文件命中时说明该目录实际有什么可搜的扩展名，避免被读成"目录不存在"
	if all_files.is_empty():
		return ToolResult.fail(_build_no_file_message(path, extensions, rejected_exts))
	
	var truncated_files: bool = all_files.size() > MAX_FILES
	if truncated_files:
		all_files.resize(MAX_FILES)
	
	# --- 依次搜索 ---
	var match_files: Array[Dictionary] = []
	var total_match_lines: int = 0
	var skipped_large: int = 0
	var skipped_binary: int = 0
	var unreadable: int = 0
	
	for file_path in all_files:
		var budget: int = MAX_RESULTS - total_match_lines
		if budget <= 0:
			break
		
		var scan: Dictionary = _scan_file(file_path, p_search, budget)
		
		if scan["skipped"]:
			skipped_large += 1
			continue
		if scan["binary"]:
			skipped_binary += 1
			continue
		if not scan["readable"]:
			unreadable += 1
			continue
		
		var lines: Array = scan.get("lines", [])
		if not lines.is_empty():
			match_files.append({"path": file_path, "lines": lines})
			total_match_lines += lines.size()
	
	# --- 命中分类统计 ---
	var strict_lines: int = 0
	var ext_lines: int = 0
	for entry in match_files:
		for hit: Dictionary in entry["lines"]:
			if hit["ext"]:
				ext_lines += 1
			else:
				strict_lines += 1
	
	# 任一降级路径成立都说明"这份结果不是全量"，必须在首行说清
	var is_partial: bool = truncated_files \
		or total_match_lines >= MAX_RESULTS \
		or skipped_large > 0 \
		or skipped_binary > 0 \
		or unreadable > 0 \
		or not rejected_exts.is_empty()
	
	# --- 构建返回 ---
	# [性能] 逐项 String += 拼接在结果较大时是 O(n²)（GDScript String 不可变）。
	# 统一改为收集后一次 join。
	var parts: PackedStringArray = PackedStringArray()
	if is_partial:
		parts.append("[PARTIAL] This folder was not searched in full — the [WARN] lines below say which parts were skipped. Do not read it as \"no other matches\".\n\n")
	parts.append("Search result for \"%s\" in `%s`:\n" % [_truncate(p_search), path])
	parts.append("  Scanned: %d files (%s) | Mode: case-sensitive, boundary-aware\n" % [all_files.size(), ", ".join(extensions)])
	parts.append("  Matches: %d files, %d lines (strict %d / ext %d)\n" % [match_files.size(), total_match_lines, strict_lines, ext_lines])
	
	# 所有降级路径都必须可见，否则 AI 会把"没扫到的范围"误判成"没有引用"
	if not rejected_exts.is_empty():
		parts.append("  [WARN] Ignored unsupported extension(s), Support extension(s): %s\n" % ", ".join(ALLOWED_EXTENSIONS))
	if truncated_files:
		parts.append("  [WARN] Folder exceeds %d files: only the first %d (sorted by path) were scanned. Results are INCOMPLETE — narrow `path`.\n" % [MAX_FILES, MAX_FILES])
	if skipped_large > 0:
		parts.append("  [WARN] %d file(s) skipped (larger than %d bytes).\n" % [skipped_large, MAX_FILE_SIZE])
	if skipped_binary > 0:
		parts.append("  [WARN] %d file(s) skipped (not text-based, contain null bytes).\n" % skipped_binary)
	if unreadable > 0:
		parts.append("  [WARN] %d file(s) could not be read.\n" % unreadable)
	if total_match_lines >= MAX_RESULTS:
		parts.append("  [WARN] Result limit reached (%d matching lines). More matches may exist — narrow `path` or `extensions`.\n" % MAX_RESULTS)
	
	if match_files.is_empty():
		parts.append("\n── No matches found ──\n")
		var relaxed: Dictionary = _relaxed_scan(all_files, p_search)
		if relaxed["sub_lines"] > 0:
			parts.append("  [HINT] %d line(s) in %d file(s) contain \"%s\" only as a substring of a longer identifier.\n" % [relaxed["sub_lines"], relaxed["sub_files"], _truncate(p_search)])
			if not relaxed["samples"].is_empty():
				parts.append("         e.g. %s\n" % ", ".join(relaxed["samples"]))
		elif relaxed["ci_lines"] > 0:
			parts.append("  [HINT] %d line(s) in %d file(s) match only case-insensitively — check the spelling / casing.\n" % [relaxed["ci_lines"], relaxed["ci_files"]])
		else:
			parts.append("  [HINT] Relaxed scan (no boundary, case-insensitive) found nothing either: the symbol is very likely absent from these files.\n")
		if relaxed["limited"]:
			parts.append("  [WARN] Relaxed scan is limited to %d files; the hint above is not exhaustive.\n" % RELAXED_SCAN_MAX_FILES)
		return ToolResult.ok("".join(parts))
	
	parts.append("\n── Matches ──\n")
	if ext_lines > 0:
		parts.append("  Tag `ext`: the hit lies inside a longer identifier (e.g. `get_node` inside `get_node_or_null`).\n")
	if _has_ctx_tag(match_files):
		parts.append("  Tag `comment` / `string`: the hit lies inside a comment / a string literal.\n")
	
	for entry in match_files:
		parts.append("%s\n" % entry["path"])
		for hit: Dictionary in entry["lines"]:
			parts.append("  Line %d%s: %s\n" % [hit["line"], _format_flags(hit), hit["text"]])
		parts.append("\n")
	
	AIChatLogger.debug("[search_in_files] \"%s\" in %s (%s) -> %d file(s), %d line(s) (%d ext)" % [_truncate(p_search), path, ", ".join(extensions), match_files.size(), total_match_lines, ext_lines])
	
	return ToolResult.ok("".join(parts))


# mode = "doc"：搜索本地离线文档，标题优先，正文兜底，只返回文档路径
func _execute_doc_mode(p_args: Dictionary, p_search: String) -> ToolResult:
	var keywords: PackedStringArray = _parse_keywords(p_search)
	if keywords.is_empty():
		return ToolResult.fail("Error: Keywords cannot be empty.")
	
	var path: String = str(p_args.get("path", "")).strip_edges()
	if path.is_empty():
		path = LOCAL_DOC_PATH
	if not path.begins_with("res://"):
		return ToolResult.fail("Error: Path must start with 'res://'.")
	if ".." in path:
		return ToolResult.fail("Error: Path traversal ('..') is not allowed.")
	
	# 收集本地文档；目录不存在或为空时区分两种情况分别告知
	var doc_files: Array[String] = []
	_collect_doc_files(path, doc_files)
	doc_files.sort()
	if doc_files.is_empty():
		if path == LOCAL_DOC_PATH:
			return ToolResult.fail(_build_missing_docs_message())
		return ToolResult.fail("Error: No document (%s) found in: %s" % [", ".join(DOC_EXTENSIONS), path])
	
	var sections: PackedStringArray = PackedStringArray()
	var warns: PackedStringArray = PackedStringArray()
	var is_partial: bool = false
	var has_any_match: bool = false
	
	for kw in keywords:
		# 第一级：标题匹配。命中即止，不再为同一关键词扫正文（省掉几乎全部 IO，也避免正文噪音）
		var title_matches: Array[String] = _search_doc_titles(doc_files, kw)
		if not title_matches.is_empty():
			has_any_match = true
			sections.append(_format_title_matches(kw, title_matches))
			continue
		
		# 第二级：正文匹配。只收集命中文件的路径，不统计行号
		var content_result: Dictionary = _search_doc_contents(doc_files, kw)
		var content_paths: Array[String] = content_result["paths"]
		if not content_paths.is_empty():
			has_any_match = true
		
		if content_result["limited"]:
			is_partial = true
			warns.append("  [WARN] Body scan for `%s` covered only %d of %d documents (title-related ones first). Narrow `path` or use a more specific keyword.\n" % [kw, content_result["scanned"], doc_files.size()])
		if content_result["hit_limit"]:
			is_partial = true
			warns.append("  [WARN] Body match limit reached (%d documents) for `%s`; more documents may match.\n" % [DOC_CONTENT_MAX_RESULTS, kw])
		
		sections.append(_format_content_matches(kw, content_paths))
	
	if p_args.has("extensions"):
		warns.append("  [WARN] `extensions` is ignored in mode=\"doc\"; document formats searched: %s.\n" % ", ".join(DOC_EXTENSIONS))
	
	var parts: PackedStringArray = PackedStringArray()
	if is_partial:
		parts.append("[PARTIAL] Not every document was body-scanned — see the [WARN] lines below. A keyword listed as \"no match\" may still appear in an unscanned document.")
	
	parts.append("Local docs: `%s` (%d documents)" % [path, doc_files.size()])
	if not warns.is_empty():
		parts.append("".join(warns).rstrip("\n"))
	
	parts.append("\n\n".join(sections))
	if has_any_match:
		parts.append("Use `read_file` on a matched path to read the content.")
	else:
		parts.append("No document matched. Titles are matched first, then document bodies (document formats only, never script sources). Try a shorter keyword, or use `search_web` / `fetch_web_content` for online docs.")
	
	return ToolResult.ok("\n\n".join(parts))


# --- Private Functions: Text Mode ---

# 解析 extensions 参数：统一小写、剥离 "*" 与 "." 前缀、去重，并剔除白名单外的项
# [return] {extensions: Array[String], rejected: Array[String]}
#   - extensions: 实际用于扫描的扩展名；若全部无效则回退 DEFAULT_EXTENSIONS
#   - rejected:   被白名单拒绝的扩展名（调用方需在输出中告警，避免"以为搜过了"）
func _resolve_extensions(p_raw: Variant) -> Dictionary:
	var resolved: Array[String] = []
	var rejected: Array[String] = []
	
	if p_raw is Array:
		for item: Variant in (p_raw as Array):
			var ext: String = str(item).strip_edges().to_lower().trim_prefix("*").trim_prefix(".")
			if ext.is_empty():
				continue
			if not ext in ALLOWED_EXTENSIONS:
				if not ext in rejected:
					rejected.append(ext)
				continue
			if not ext in resolved:
				resolved.append(ext)
	
	if resolved.is_empty():
		resolved.assign(DEFAULT_EXTENSIONS)
	
	return {"extensions": resolved, "rejected": rejected}


# 递归收集指定扩展名的文件
# [param p_limit]: 收集上限（>0 时超限即停止递归），用于把 MAX_FILES 的判断前移，避免白扫上万文件
# 目录与文件均先排序再处理，保证"前 N 个文件"是确定性的
func _collect_files(p_folder: String, p_extensions: Array[String], p_results: Array[String], p_limit: int) -> void:
	if p_limit > 0 and p_results.size() >= p_limit:
		return
	
	var dir: DirAccess = DirAccess.open(p_folder)
	if not dir:
		return
	
	var sub_dirs: Array[String] = []
	var files: Array[String] = []
	
	dir.list_dir_begin()
	var entry_name: String = dir.get_next()
	
	while entry_name != "":
		if entry_name == "." or entry_name == "..":
			entry_name = dir.get_next()
			continue
		
		var full_path: String = p_folder.path_join(entry_name)
		
		if dir.current_is_dir():
			# 剪枝：缓存 / 版本控制 / 备份目录里的文件不应占用搜索预算
			if not entry_name in PRUNED_DIRS:
				sub_dirs.append(full_path)
		elif entry_name.get_extension().to_lower() in p_extensions:
			files.append(full_path)
		
		entry_name = dir.get_next()
	
	dir.list_dir_end()
	
	sub_dirs.sort()
	files.sort()
	
	for file_path in files:
		if p_limit > 0 and p_results.size() >= p_limit:
			return
		p_results.append(file_path)
	
	for sub_dir in sub_dirs:
		if p_limit > 0 and p_results.size() >= p_limit:
			return
		_collect_files(sub_dir, p_extensions, p_results, p_limit)


# 构建"目录内没有可搜索文件"的提示
# 除错误本身外还会列出该目录实际存在的白名单扩展名及数量 —— 否则 AI 极易把
# "没有 .gd 文件"读成"目录不存在 / 没有相关内容"（如对 res://godot_doc 用默认扩展名搜索）
func _build_no_file_message(p_path: String, p_extensions: Array[String], p_rejected: Array[String]) -> String:
	var parts: PackedStringArray = PackedStringArray()
	parts.append("Error: No file with extension(s) [%s] found in: %s" % [", ".join(p_extensions), p_path])
	
	if not p_rejected.is_empty():
		parts.append("[WARN] Ignored unsupported extension(s), Support extension(s): %s" % ", ".join(ALLOWED_EXTENSIONS))
	
	# 只在零命中时做这次探测，代价可忽略
	var present: PackedStringArray = PackedStringArray()
	var present_args: PackedStringArray = PackedStringArray()
	for ext in ALLOWED_EXTENSIONS:
		var one_ext: Array[String] = [ext]
		var found: Array[String] = []
		_collect_files(p_path, one_ext, found, MAX_FILES)
		if not found.is_empty():
			present.append("%s (%d)" % [ext, found.size()])
			present_args.append("\"%s\"" % ext)
	
	if present.is_empty():
		parts.append("[HINT] This folder holds no searchable text file at all (supported: %s)." % ", ".join(ALLOWED_EXTENSIONS))
	else:
		parts.append("[HINT] Searchable files present here: %s. Retry with extensions=[%s]." % [", ".join(present), ", ".join(present_args)])
	
	return "\n".join(parts)


# 读取文件并做统一预处理
# [return] {readable: bool, skipped: bool, binary: bool, content: String}
#   - skipped: 文件超过 MAX_FILE_SIZE
#   - binary:  内容含 null 字节，判定为非文本文件
# 注意：必须先按字节读取并检查 NUL，不能直接 get_as_text()。
# 后者会先做 UTF-8 校验，遇到 NUL 时调用引擎 ERR_PRINT 打印
# "Unicode parsing error ... Unexpected NUL character"，污染编辑器输出。
func _read_text_file(p_path: String) -> Dictionary:
	var result: Dictionary = {
		"readable": false,
		"skipped": false,
		"binary": false,
		"content": "",
	}
	
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not is_instance_valid(file):
		return result
	
	var file_size: int = file.get_length()
	if file_size > MAX_FILE_SIZE:
		file.close()
		result["skipped"] = true
		return result
	
	var bytes: PackedByteArray = file.get_buffer(file_size)
	file.close()
	
	if bytes.find(0) != -1:
		result["binary"] = true
		return result
	
	result["readable"] = true
	# 统一换行符，保证行号统计与编辑器一致
	result["content"] = bytes.get_string_from_utf8().replace("\r\n", "\n").replace("\r", "\n")
	return result


# 扫描单个文件，返回命中行（1-based，升序、已按行去重）
# [param p_budget]: 命中行数上限，0 表示不限
# [return] {readable: bool, skipped: bool, binary: bool, lines: Array[Dictionary]}
#   每项形如 {line: int, ext: bool, ctx: int, text: String}
# [性能] 用 find() 增量推进换行游标统计行号，整体 O(文件长度)；
# 上下文标记与行内容只对命中行做局部扫描，最多 MAX_RESULTS 次。
func _scan_file(p_path: String, p_search: String, p_budget: int) -> Dictionary:
	var read_result: Dictionary = _read_text_file(p_path)
	var scan_result: Dictionary = {
		"readable": read_result["readable"],
		"skipped": read_result["skipped"],
		"binary": read_result["binary"],
		"lines": [] as Array[Dictionary],
	}
	if not read_result["readable"]:
		return scan_result
	
	var content: String = read_result["content"]
	var search_len: int = p_search.length()
	if search_len > content.length():
		return scan_result
	
	# 只有搜索串首/尾本身是标识符字符时，该侧才需要边界检查
	var check_left: bool = _is_ident_code(p_search.unicode_at(0))
	var check_right: bool = _is_ident_code(p_search.unicode_at(search_len - 1))
	
	var hits: Array[Dictionary] = []
	var hit_map: Dictionary = {}
	var pos: int = 0
	# 换行游标：[0, nl_scan_pos) 区间内的换行已统计完毕，避免为每个匹配重复扫描
	var nl_scan_pos: int = 0
	var nl_count: int = 0
	var line_start: int = 0
	
	while pos < content.length():
		var found: int = content.find(p_search, pos)
		if found == -1:
			break
		
		var match_end: int = found + search_len
		var verdict: int = _classify_boundary(content, found, match_end, check_left, check_right)
		if verdict == BOUNDARY_FAIL:
			pos = found + 1  # 跳过，继续往后搜
			continue
		
		# 增量推进到匹配位置之前的所有换行 → 1-based 行号
		while true:
			var nl: int = content.find("\n", nl_scan_pos)
			if nl == -1 or nl >= found:
				break
			nl_count += 1
			nl_scan_pos = nl + 1
			line_start = nl + 1
		
		var current_line: int = nl_count + 1
		var is_ext: bool = verdict == BOUNDARY_EXTENDED
		
		if hit_map.has(current_line):
			# 按行去重；同一行既有 ext 又有 strict 命中时，以 strict 为准
			if not is_ext:
				var existing: Dictionary = hit_map[current_line]
				existing["ext"] = false
		else:
			# 行内容：从行首到下一个换行。缩进不影响定位，strip 掉以省宽度
			var line_end: int = content.find("\n", found)
			if line_end == -1:
				line_end = content.length()
			var entry: Dictionary = {
				"line": current_line,
				"ext": is_ext,
				# 只截取行首到命中点，用于判断命中是否落在注释 / 字符串内
				"ctx": _analyze_prefix(content.substr(line_start, found - line_start)),
				"text": _truncate_line(content.substr(line_start, line_end - line_start).strip_edges()),
			}
			hit_map[current_line] = entry
			hits.append(entry)
			if p_budget > 0 and hits.size() >= p_budget:
				break
		
		pos = match_end
	
	scan_result["lines"] = hits
	return scan_result


# 判定一次命中的边界质量
# 规则：仅检查"搜索串该侧本身是标识符字符"的那一侧
#   - 相邻字符不是标识符字符 → 视为边界正常
#   - 相邻字符是下划线       → 视为更长标识符内的命中（BOUNDARY_EXTENDED）
#   - 相邻字符是字母/数字    → 判定为不同标识符（BOUNDARY_FAIL）
func _classify_boundary(p_content: String, p_start: int, p_end: int, p_check_left: bool, p_check_right: bool) -> int:
	var extended: bool = false
	
	if p_check_left and p_start > 0:
		var left_code: int = p_content.unicode_at(p_start - 1)
		if _is_ident_code(left_code):
			if left_code == 0x5F:  # '_'
				extended = true
			else:
				return BOUNDARY_FAIL
	
	if p_check_right and p_end < p_content.length():
		var right_code: int = p_content.unicode_at(p_end)
		if _is_ident_code(right_code):
			if right_code == 0x5F:  # '_'
				extended = true
			else:
				return BOUNDARY_FAIL
	
	return BOUNDARY_EXTENDED if extended else BOUNDARY_STRICT


# 判断行内前缀（行首 → 命中点）的状态，得出命中所在的上下文
# 只扫描前缀，成本是 O(行长度)
func _analyze_prefix(p_prefix: String) -> int:
	var quote: int = 0  # 0 = 不在字符串内, 1 = 双引号内, 2 = 单引号内
	var i: int = 0
	var prefix_len: int = p_prefix.length()
	
	while i < prefix_len:
		var c: int = p_prefix.unicode_at(i)
		if quote != 0:
			if c == 0x5C:  # '\\' 转义，跳过下一个字符
				i += 2
				continue
			if quote == 1 and c == 0x22:  # '"'
				quote = 0
			elif quote == 2 and c == 0x27:  # '\''
				quote = 0
		else:
			if c == 0x22:
				quote = 1
			elif c == 0x27:
				quote = 2
			elif c == 0x23:  # '#' 注释起点（此前的引号均已闭合）
				return CTX_COMMENT
		i += 1
	
	return CTX_STRING if quote != 0 else CTX_NONE


# 宽松扫描：只在主查询零命中时调用
# 区分两种失败原因：命中的只是更长标识符的子串 / 仅大小写不符
func _relaxed_scan(p_files: Array[String], p_search: String) -> Dictionary:
	var scanned: int = 0
	var sub_files: int = 0
	var sub_lines: int = 0
	var ci_files: int = 0
	var ci_lines: int = 0
	var samples: Array[String] = []
	var limit: int = mini(p_files.size(), RELAXED_SCAN_MAX_FILES)
	var lower_search: String = p_search.to_lower()
	
	for i in range(limit):
		var read_result: Dictionary = _read_text_file(p_files[i])
		if not read_result["readable"]:
			continue
		
		var content: String = read_result["content"]
		scanned += 1
		
		# 无边界匹配（仍区分大小写）
		var sub: int = _count_lines_containing(content, p_search)
		if sub > 0:
			sub_files += 1
			sub_lines += sub
			if samples.size() < 3:
				samples.append(p_files[i])
			continue
		
		# 无论 p_search 自身大小写如何，content 里都可能是另一种大小写，必须始终比对一次
		var ci: int = _count_lines_containing(content.to_lower(), lower_search)
		if ci > 0:
			ci_files += 1
			ci_lines += ci
	
	return {
		"scanned": scanned,
		"limited": p_files.size() > RELAXED_SCAN_MAX_FILES,
		"sub_files": sub_files,
		"sub_lines": sub_lines,
		"ci_files": ci_files,
		"ci_lines": ci_lines,
		"samples": samples,
	}


# 统计包含 p_needle 的行数（按行去重）
func _count_lines_containing(p_content: String, p_needle: String) -> int:
	if p_needle.is_empty():
		return 0
	
	var count: int = 0
	var last_line: int = -1
	var pos: int = 0
	var nl_scan_pos: int = 0
	var nl_count: int = 0
	var needle_len: int = p_needle.length()
	
	while pos < p_content.length():
		var found: int = p_content.find(p_needle, pos)
		if found == -1:
			break
		
		while true:
			var nl: int = p_content.find("\n", nl_scan_pos)
			if nl == -1 or nl >= found:
				break
			nl_count += 1
			nl_scan_pos = nl + 1
		
		var current_line: int = nl_count + 1
		if current_line != last_line:
			last_line = current_line
			count += 1
		
		pos = found + needle_len
	
	return count


# 判断字符码是否为标识符字符（字母、数字、下划线）
func _is_ident_code(p_code: int) -> bool:
	return (p_code >= 0x30 and p_code <= 0x39) \
		or (p_code >= 0x41 and p_code <= 0x5A) \
		or (p_code >= 0x61 and p_code <= 0x7A) \
		or p_code == 0x5F


# 是否出现任何上下文标记（决定是否需要打印标记说明）
func _has_ctx_tag(p_match_files: Array[Dictionary]) -> bool:
	for entry in p_match_files:
		for hit: Dictionary in entry["lines"]:
			if hit["ctx"] != CTX_NONE:
				return true
	return false


# 把命中项格式化为行号后缀，如 " (ext, comment)"
func _format_flags(p_hit: Dictionary) -> String:
	var tags: PackedStringArray = PackedStringArray()
	if p_hit["ext"]:
		tags.append("ext")
	
	var ctx: int = p_hit["ctx"]
	if ctx == CTX_COMMENT:
		tags.append("comment")
	elif ctx == CTX_STRING:
		tags.append("string")
	
	if tags.is_empty():
		return ""
	return " (" + ", ".join(tags) + ")"


# 截断超长行内容，保留可读前缀；"…" 本身即为"被截断"的自解释信号
func _truncate_line(p_line: String) -> String:
	if p_line.length() <= MAX_LINE_CHARS:
		return p_line
	return p_line.substr(0, MAX_LINE_CHARS) + "…"


func _truncate(p_text: String, p_max_len: int = 60) -> String:
	if p_text.length() <= p_max_len:
		return p_text
	return p_text.substr(0, p_max_len) + "..."


# --- Private Functions: Doc Mode ---

# 解析关键词：支持数组或字符串（以空格/逗号分隔），并过滤空项
func _parse_keywords(p_keyword_input: Variant) -> PackedStringArray:
	var result: PackedStringArray = []
	
	if p_keyword_input is Array:
		for i in p_keyword_input:
			var item: String = str(i).strip_edges()
			if not item.is_empty():
				result.append(item)
	else:
		var parts: PackedStringArray = str(p_keyword_input).replace(",", " ").split(" ", false)
		for p in parts:
			var item: String = p.strip_edges()
			if not item.is_empty():
				result.append(item)
	
	return result


# 递归收集指定扩展名的文档文件（跳过隐藏文件/目录）
func _collect_doc_files(p_dir_path: String, p_result: Array[String]) -> void:
	var dir: DirAccess = DirAccess.open(p_dir_path)
	if dir == null:
		return
	
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	
	while not file_name.is_empty():
		# 跳过 "." / ".." 以及隐藏文件/目录
		if file_name.begins_with("."):
			file_name = dir.get_next()
			continue
		
		var full_path: String = p_dir_path.path_join(file_name)
		if dir.current_is_dir():
			_collect_doc_files(full_path, p_result)
		elif DOC_EXTENSIONS.has(file_name.get_extension().to_lower()):
			p_result.append(full_path)
		
		file_name = dir.get_next()
	
	dir.list_dir_end()


# 关键词归一化：仅转小写并去除首尾空白
func _normalize_keyword(p_keyword: String) -> String:
	return p_keyword.to_lower().strip_edges()


# 对文档列表做标题模糊匹配，返回按匹配优先级排序的路径
# 优先级：全等 > 前缀 > 包含 > 路径包含
# `Class.member` 回退：完整关键词无命中时，只用 `.` 前的类名再试一次
func _search_doc_titles(p_doc_files: Array[String], p_keyword: String) -> Array[String]:
	var keyword: String = _normalize_keyword(p_keyword)
	if keyword.is_empty():
		return []
	
	var matches: Array[String] = _match_titles(p_doc_files, keyword)
	
	if matches.is_empty() and "." in keyword:
		matches = _match_titles(p_doc_files, keyword.get_slice(".", 0).strip_edges())
	
	return matches


# 单次标题匹配，不做任何关键词截断/回退
func _match_titles(p_doc_files: Array[String], p_keyword: String) -> Array[String]:
	var keyword: String = p_keyword.to_lower().strip_edges()
	if keyword.is_empty():
		return []
	
	var keyword_compact: String = _strip_separators(keyword)
	
	var exact: Array[String] = []
	var prefix: Array[String] = []
	var contains: Array[String] = []
	var path_hit: Array[String] = []
	
	for doc_path in p_doc_files:
		var title: String = _extract_doc_title(doc_path)
		var title_compact: String = _strip_separators(title)
		
		if title == keyword or title_compact == keyword_compact:
			exact.append(doc_path)
		elif title.begins_with(keyword) or title_compact.begins_with(keyword_compact):
			prefix.append(doc_path)
		elif keyword in title or (keyword_compact.length() >= 3 and keyword_compact in title_compact):
			contains.append(doc_path)
		elif keyword in doc_path.to_lower():
			path_hit.append(doc_path)
	
	var result: Array[String] = []
	result.append_array(exact)
	result.append_array(prefix)
	result.append_array(contains)
	result.append_array(path_hit)
	return result


# 在文档正文中做大小写不敏感的子串匹配，只收集命中文件的路径（不统计行号）
# 标题与关键词相关的文档优先扫描：概念性提问的命中更容易集中在这类文档里
# [return] {paths: Array[String], scanned: int, limited: bool, hit_limit: bool}
func _search_doc_contents(p_doc_files: Array[String], p_keyword: String) -> Dictionary:
	var needle: String = _normalize_keyword(p_keyword)
	
	var paths: Array[String] = []
	var scanned: int = 0
	var hit_limit: bool = false
	
	if needle.is_empty():
		return {"paths": paths, "scanned": scanned, "limited": false, "hit_limit": hit_limit}
	
	var prioritized: Array[String] = []
	var rest: Array[String] = []
	for doc_path in p_doc_files:
		if needle in _extract_doc_title(doc_path):
			prioritized.append(doc_path)
		else:
			rest.append(doc_path)
	prioritized.append_array(rest)
	
	var limit: int = mini(prioritized.size(), DOC_CONTENT_MAX_FILES)
	for i in range(limit):
		if paths.size() >= DOC_CONTENT_MAX_RESULTS:
			hit_limit = true
			break
		
		var read_result: Dictionary = _read_text_file(prioritized[i])
		scanned += 1
		if not read_result["readable"]:
			continue
		if needle in String(read_result["content"]).to_lower():
			paths.append(prioritized[i])
	
	return {
		"paths": paths,
		"scanned": scanned,
		"limited": prioritized.size() > DOC_CONTENT_MAX_FILES,
		"hit_limit": hit_limit,
	}


# 提取文档标题：文件名去扩展名、转小写、去掉 `class_` 前缀
func _extract_doc_title(p_path: String) -> String:
	return p_path.get_file().get_basename().to_lower().trim_prefix("class_")


# 去除分隔符，用于忽略下划线/连字符/空格的差异（如 `input_event` 与 `inputevent`）
func _strip_separators(p_text: String) -> String:
	return p_text.replace("_", "").replace("-", "").replace(" ", "")


# 格式化标题匹配结果（只列路径）
func _format_title_matches(p_keyword: String, p_matches: Array[String]) -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("## `%s` — %d title match(es)" % [p_keyword, p_matches.size()])
	
	var limit: int = mini(p_matches.size(), MAX_TITLE_RESULTS_PER_KEYWORD)
	for i in range(limit):
		lines.append("- `%s`" % p_matches[i])
	if p_matches.size() > limit:
		lines.append("- ... (%d more)" % (p_matches.size() - limit))
	
	return "\n".join(lines)


# 格式化正文匹配结果（只列路径，不含行号与内容）
func _format_content_matches(p_keyword: String, p_paths: Array[String]) -> String:
	var lines: PackedStringArray = PackedStringArray()
	if p_paths.is_empty():
		lines.append("## `%s` — no title or body match" % p_keyword)
		return "\n".join(lines)
	
	lines.append("## `%s` — %d body match(es)" % [p_keyword, p_paths.size()])
	for doc_path in p_paths:
		lines.append("- `%s`" % doc_path)
	
	return "\n".join(lines)


# 构建「本地文档缺失/为空」的提示信息
func _build_missing_docs_message() -> String:
	var reason: String = "does not exist"
	if DirAccess.dir_exists_absolute(LOCAL_DOC_PATH):
		reason = "exists but contains no document"
	
	var lines: PackedStringArray = PackedStringArray()
	lines.append("Local Godot documentation unavailable: `%s` %s." % [LOCAL_DOC_PATH, reason])
	lines.append("mode=\"doc\" searches that folder only, so the search could not be performed.")
	lines.append("")
	lines.append("**How to enable it:**")
	lines.append("1. Download the offline HTML documentation matching your Godot version (from the official Godot docs website, \"Offline documentation\" → HTML).")
	lines.append("2. Convert it to Markdown with `%s`:" % DOC_CONVERSION_REPO_URL)
	lines.append("   - `html2md_for_godot_doc.py` — Sphinx HTML → Markdown, keeps the original folder structure.")
	lines.append("   - `clean_md_files.py` — removes redundant anchor links, `.html` links, images and page footers.")
	lines.append("3. Copy the converted Markdown tree into the project as `%s/` (keep the subfolders, e.g. `classes/`)." % LOCAL_DOC_PATH)
	lines.append("")
	lines.append("Until then, use `search_web` / `fetch_web_content` to look up Godot API documentation online.")
	
	return "\n".join(lines)
