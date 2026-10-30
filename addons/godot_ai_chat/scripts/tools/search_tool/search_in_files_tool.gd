extends AiTool

## 文本搜索工具：在指定文件夹的文本文件中查找某段内容（符号、字符串、资源路径等）的所有出现位置。
##
## 使用场景：
## - 引用定位：某函数 / 变量 / 类名 / 资源路径在哪些地方被引用
## - 重构影响分析：找出哪些文件引用了即将废弃的 API，或哪些场景 / 资源引用了某个脚本
## - 代码审计：查找项目中的危险模式或重复代码
## - 跨格式检索：`extensions` 可在白名单内指定 gd / tscn / tres / md / json 等文本格式
##
## 匹配语义刻意写死、不开放为参数：
## - 大小写敏感：贴合"已知拼写准确定位"的调用前提；大小写不符由零命中时的宽松扫描提示兜底。
## - 边界检查只作用于搜索串首/尾本身是标识符字符的那一侧：
##   `get_node(`、`.new(`、`"res://a.gd"` 这类以符号收尾的片段，不会因为前一个字符是标识符字符被误判。
## - 下划线相邻的命中（`get_node` 之于 `get_node_or_null`）归为 `ext` 命中：
##   默认汇报但显式标注，既不吞掉前缀类搜索，也不会被当成精确引用。
##
## 只返回行号、不返回行原文，这是刻意的接口设计：
## 拿到行号后必须用 read_file 读取目标文件，才能判断该命中是定义、调用还是注释中的提及。
## 若回带单行原文，AI 会倾向于"已经知道这行是什么"而跳过 read_file，
## 凭单行片段下结论 —— 半信息比明显不足的信息更危险。
## 行号后可附极短上下文标记（ext / comment / string），只描述"这一行是什么性质"，
## 不提供原文，仍然迫使调用方 read_file 确认。
##
## 所有降级路径（文件过大跳过 / 二进制跳过 / 扩展名被拒 / 文件数触顶 / 结果数触顶 /
## 宽松扫描受限）都会在输出中显式告警，避免 AI 把"没扫到的范围"误判成"没有引用"。
## 主查询零命中时追加一次宽松扫描（去边界 / 忽略大小写），用于区分"确实没有"与"拼写 / 大小写不符"。


# --- Constants ---

## 允许搜索的扩展名白名单（仅文本格式）。extensions 参数只能取此列表的子集。
const ALLOWED_EXTENSIONS: Array[String] = ["gd", "tscn", "tres", "gdshader", "glsl", "cfg", "md"]

## 默认搜索的扩展名（未传 extensions 或所传扩展名全部无效时使用）
const DEFAULT_EXTENSIONS: Array[String] = ["gd"]

## 单个文件大小上限（超过此大小的文件跳过，防止大文件卡死）
const MAX_FILE_SIZE: int = 1024 * 1024  # 1 MB

## 最大搜索文件数（防止文件夹过大导致超时）
const MAX_FILES: int = 500

## 命中行数上限（触顶时输出告警，提示缩小搜索范围）
const MAX_RESULTS: int = 500

## 遍历时直接跳过的目录：缓存 / 版本控制 / 备份 / 第三方构建产物
## 否则排序后靠前的缓存文件会吃掉 MAX_FILES 预算，导致真正的代码没被扫到
const PRUNED_DIRS: Array[String] = [
	".godot", ".git", ".import", ".svn", "node_modules", "__pycache__", "rollback_files",
]

## 宽松扫描的文件数上限（只在主查询零命中时触发）
const RELAXED_SCAN_MAX_FILES: int = 200

## 边界判定结果
const BOUNDARY_FAIL: int = 0
const BOUNDARY_STRICT: int = 1
const BOUNDARY_EXTENDED: int = 2

## 命中行的上下文标记（位标记）
const CTX_NONE: int = 0
const CTX_COMMENT: int = 1
const CTX_STRING: int = 2


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "search_in_files"
	tool_description = "Searches text files in a target folder for specific content matches."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path of the folder to search. Scanned recursively."
			},
			"search": {
				"type": "string",
				"description": "Exact symbol or snippet to find. Case-sensitive, single line; hits inside longer identifiers are tagged `ext`."
			},
			"extensions": {
				"type": "array",
				"items": { "type": "string" },
				"description": "Text-based file extensions to scan, Support: gd, tscn, tres, gdshader, glsl, cfg, md. Default: gd."
			}
		},
		"required": ["path", "search"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var path: String = str(p_args.get("path", "")).strip_edges()
	var search: String = str(p_args.get("search", ""))
	
	# --- 参数校验 ---
	if path.is_empty():
		return ToolResult.fail("Missing parameter: path")
	if search.is_empty():
		return ToolResult.fail("Missing parameter: search")
	if not path.begins_with("res://"):
		return ToolResult.fail("Error: Path must start with 'res://'.")
	if ".." in path:
		return ToolResult.fail("Error: Path traversal ('..') is not allowed.")
	if not DirAccess.dir_exists_absolute(path):
		return ToolResult.fail("Error: Folder not found: " + path)
	# schema 声明 single-line only，这里必须实际兜住，否则跨行 search 会命中但行号只记起始行
	if "\n" in search or "\r" in search:
		return ToolResult.fail("Error: `search` must be a single line.")
	
	var ext_result: Dictionary = _resolve_extensions(p_args.get("extensions"))
	var extensions: Array[String] = ext_result["extensions"]
	var rejected_exts: Array[String] = ext_result["rejected"]
	
	# --- 收集文件（多收 1 个用于判断是否触顶）---
	var all_files: Array[String] = []
	_collect_scripts(path, extensions, all_files, MAX_FILES + 1)
	# 排序：保证同一查询两次返回顺序一致，便于前后比对
	all_files.sort()
	
	if all_files.is_empty():
		return ToolResult.fail("Error: No files with extension(s) [%s] found in: %s" % [", ".join(extensions), path])
	
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
		
		var scan: Dictionary = _scan_file(file_path, search, budget)
		
		if scan.get("skipped", false):
			skipped_large += 1
			continue
		if scan.get("binary", false):
			skipped_binary += 1
			continue
		if not scan.get("readable", false):
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
	
	# --- 构建返回 ---
	# [性能] 逐项 String += 拼接在结果较大时是 O(n²)（GDScript String 不可变）。
	# 统一改为收集后一次 join。
	var parts: PackedStringArray = PackedStringArray()
	parts.append("Search result for \"%s\" in `%s`:\n" % [_truncate(search), path])
	parts.append("  Scanned: %d files (%s) | Mode: case-sensitive, boundary-aware\n" % [all_files.size(), ", ".join(extensions)])
	parts.append("  Matches: %d files, %d lines (strict %d / ext %d)\n" % [match_files.size(), total_match_lines, strict_lines, ext_lines])
	
	# 所有降级路径都必须可见，否则 AI 会把"没扫到的范围"误判成"没有引用"
	if not rejected_exts.is_empty():
		parts.append("  [WARN] Ignored unsupported extension(s): [%s]. Allowed: [%s].\n" % [", ".join(rejected_exts), ", ".join(ALLOWED_EXTENSIONS)])
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
		var relaxed: Dictionary = _relaxed_scan(all_files, search)
		if relaxed["sub_lines"] > 0:
			parts.append("  [HINT] %d line(s) in %d file(s) contain \"%s\" only as a substring of a longer identifier.\n" % [relaxed["sub_lines"], relaxed["sub_files"], _truncate(search)])
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
			parts.append("  Line %d%s\n" % [hit["line"], _format_flags(hit)])
		parts.append("\n")
	
	AIChatLogger.debug("[search_in_files] \"%s\" in %s (%s) -> %d file(s), %d line(s) (%d ext)" % [_truncate(search), path, ", ".join(extensions), match_files.size(), total_match_lines, ext_lines])
	
	return ToolResult.ok("".join(parts))


# --- Private Functions ---

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
func _collect_scripts(p_folder: String, p_extensions: Array[String], p_results: Array[String], p_limit: int) -> void:
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
		_collect_scripts(sub_dir, p_extensions, p_results, p_limit)


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
#   每项形如 {line: int, ext: bool, ctx: int}
# [性能] 用 find() 增量推进换行游标统计行号，整体 O(文件长度)；
# 上下文标记只对命中行做局部扫描，最多 MAX_RESULTS 次。
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
			var entry: Dictionary = {
				"line": current_line,
				"ext": is_ext,
				# 只截取行首到命中点，用于判断命中是否落在注释 / 字符串内
				"ctx": _analyze_prefix(content.substr(line_start, found - line_start)),
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


func _truncate(p_text: String, p_max_len: int = 60) -> String:
	if p_text.length() <= p_max_len:
		return p_text
	return p_text.substr(0, p_max_len) + "..."
