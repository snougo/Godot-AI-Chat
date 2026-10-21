@tool
extends AiTool

## 代码引用定位工具：在指定文件夹的脚本中查找某段代码符号（函数名/变量名/类名/API/资源路径）的所有引用位置。
##
## 使用场景：
## - 规范性检查：检查指定范围内的脚本是否都实现了某个函数、是否都使用了某个公共变量
## - 重构影响分析：找出哪些文件引用了即将废弃的 API，或哪些场景/资源引用了某个脚本
## - 代码审计：查找项目中的危险模式或重复代码
##
## 匹配语义刻意写死、不开放为参数，以保持 schema 精简：
## - 大小写敏感 + 词边界：贴合"已知符号准确拼写"的调用前提，
##   且 'class_name' 不会误命中 'global_class_name'。零命中即表明拼写不符，由调用方核对。
##
## 只返回行号、不返回行原文，这是刻意的接口设计：
## 拿到行号后必须用 read_file 读取目标脚本，才能判断该命中是定义、调用还是注释中的提及。
## 若回带单行原文，AI 会倾向于"已经知道这行是什么"而跳过 read_file，
## 凭单行片段下结论 —— 半信息比明显不足的信息更危险。
##
## 所有降级路径（文件过大跳过 / 文件数触顶 / 结果数触顶）都会在输出中显式告警，
## 避免 AI 把"没扫到的范围"误判成"没有引用"。


# --- Constants ---

## 默认搜索的文件扩展名
const DEFAULT_EXTENSIONS: Array[String] = ["gd"]

## 单个文件大小上限（超过此大小的文件跳过，防止大文件卡死）
const MAX_FILE_SIZE: int = 1024 * 1024  # 1 MB

## 最大搜索文件数（防止文件夹过大导致超时）
const MAX_FILES: int = 500

## 命中行数上限（触顶时输出告警，提示缩小搜索范围）
const MAX_RESULTS: int = 500


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "find_code_references"
	tool_description = "Searches all script files in a target folder for specific code content matches (e.g. function name, variable name, class name, or API call)."


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
				"description": "The exact code symbol or snippet to find (function / variable / class name, API call, or literal resource path). Case-sensitive, word-boundary aware, single-line only."
			},
			"extensions": {
				"type": "array",
				"items": { "type": "string" },
				"description": "File extensions to scan, e.g. [\"gd\"], or [\"tscn\", \"tres\"] to find which scenes/resources reference something. Default: [\"gd\"]."
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
	
	var extensions: Array[String] = _resolve_extensions(p_args.get("extensions"))
	
	# --- 收集文件 ---
	var all_files: Array[String] = []
	_collect_scripts(path, extensions, all_files)
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
	var unreadable: int = 0
	
	for file_path in all_files:
		var budget: int = MAX_RESULTS - total_match_lines
		if budget <= 0:
			break
		
		var scan: Dictionary = _scan_file(file_path, search, budget)
		
		if scan.get("skipped", false):
			skipped_large += 1
			continue
		if not scan.get("readable", false):
			unreadable += 1
			continue
		
		var lines: Array[int] = scan.get("lines", [])
		if not lines.is_empty():
			match_files.append({"path": file_path, "lines": lines})
			total_match_lines += lines.size()
	
	# --- 构建返回 ---
	# [性能] 逐项 String += 拼接在结果较大时是 O(n²)（GDScript String 不可变）。
	# 统一改为收集后一次 join。
	var parts: PackedStringArray = PackedStringArray()
	parts.append("Grep result for \"%s\" in `%s`:\n" % [_truncate(search), path])
	parts.append("  Scanned: %d files (%s) | Mode: case-sensitive, whole-word\n" % [all_files.size(), ", ".join(extensions)])
	parts.append("  Matches: %d files, %d lines\n" % [match_files.size(), total_match_lines])
	
	# 所有降级路径都必须可见，否则 AI 会把"没扫到的范围"误判成"没有引用"
	if truncated_files:
		parts.append("  [WARN] Folder exceeds %d files: only the first %d (sorted by path) were scanned. Results are INCOMPLETE — narrow `path`.\n" % [MAX_FILES, MAX_FILES])
	if skipped_large > 0:
		parts.append("  [WARN] %d file(s) skipped (larger than %d bytes).\n" % [skipped_large, MAX_FILE_SIZE])
	if unreadable > 0:
		parts.append("  [WARN] %d file(s) could not be read.\n" % unreadable)
	if total_match_lines >= MAX_RESULTS:
		parts.append("  [WARN] Result limit reached (%d matching lines). More matches may exist — narrow `path`.\n" % MAX_RESULTS)
	
	if match_files.is_empty():
		parts.append("\n── No matches found ──\n")
		return ToolResult.ok("".join(parts))
	
	parts.append("\n── Matches ──\n")
	for entry in match_files:
		parts.append("%s\n" % entry["path"])
		for line_no: int in entry["lines"]:
			parts.append("  Line %d\n" % line_no)
		parts.append("\n")
	
	AIChatLogger.debug("[find_code_references] \"%s\" in %s -> %d file(s), %d line(s)" % [_truncate(search), path, match_files.size(), total_match_lines])
	
	return ToolResult.ok("".join(parts))


# --- Private Functions ---

# 解析 extensions 参数：统一小写、剥离 "*" 与 "." 前缀、去重；无效输入回退默认值
func _resolve_extensions(p_raw: Variant) -> Array[String]:
	var result: Array[String] = []
	
	if p_raw is Array:
		for item: Variant in (p_raw as Array):
			var ext: String = str(item).strip_edges().to_lower().trim_prefix("*").trim_prefix(".")
			if not ext.is_empty() and not ext in result:
				result.append(ext)
	
	if result.is_empty():
		result.assign(DEFAULT_EXTENSIONS)
	
	return result


# 递归收集指定扩展名的文件（跳过 "." / ".."）
func _collect_scripts(p_folder: String, p_extensions: Array[String], p_results: Array[String]) -> void:
	var dir: DirAccess = DirAccess.open(p_folder)
	if not dir:
		return
	
	dir.list_dir_begin()
	var entry_name: String = dir.get_next()
	
	while entry_name != "":
		if entry_name == "." or entry_name == "..":
			entry_name = dir.get_next()
			continue
		
		var full_path: String = p_folder.path_join(entry_name)
		
		if dir.current_is_dir():
			_collect_scripts(full_path, p_extensions, p_results)
		elif entry_name.get_extension().to_lower() in p_extensions:
			p_results.append(full_path)
		
		entry_name = dir.get_next()
	
	dir.list_dir_end()


# 扫描单个文件，返回命中行号列表（1-based，升序、已按行去重）
# [param p_budget]: 命中行数上限，0 表示不限
# [return] {readable: bool, skipped: bool, lines: Array[int]}
#   - skipped: 文件超过 MAX_FILE_SIZE，未扫描
# [性能] 旧实现为每个匹配都从头逐字符扫描统计换行（O(匹配数 × 文件长度)，
# 1 MB 文件里几十个匹配即可耗费数秒）。改为用 find() 增量推进换行游标，整体 O(文件长度)。
func _scan_file(p_path: String, p_search: String, p_budget: int) -> Dictionary:
	var scan_result: Dictionary = {
		"readable": false,
		"skipped": false,
		"lines": [] as Array[int],
	}
	
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not is_instance_valid(file):
		return scan_result
	
	if file.get_length() > MAX_FILE_SIZE:
		file.close()
		scan_result["skipped"] = true
		return scan_result
	
	var content: String = file.get_as_text()
	file.close()
	scan_result["readable"] = true
	
	# 统一换行符，保证行号统计与编辑器一致
	content = content.replace("\r\n", "\n").replace("\r", "\n")
	
	var search_len: int = p_search.length()
	if search_len > content.length():
		return scan_result
	
	var hits: Array[int] = []
	var hit_flags: Dictionary = {}
	var pos: int = 0
	# 换行游标：[0, nl_scan_pos) 区间内的换行已统计完毕，避免为每个匹配重复扫描
	var nl_scan_pos: int = 0
	var nl_count: int = 0
	
	while pos < content.length():
		# 大小写敏感匹配：本工具的定位是"按已知拼写定位引用"
		var found: int = content.find(p_search, pos)
		if found == -1:
			break
		
		# 词边界检查：防止匹配到标识符的子串（如 class_name 命中 global_class_name）
		if _is_word_boundary(content, found, found + search_len):
			# 增量推进到匹配位置之前的所有换行 → 1-based 行号
			while true:
				var nl: int = content.find("\n", nl_scan_pos)
				if nl == -1 or nl >= found:
					break
				nl_count += 1
				nl_scan_pos = nl + 1
			
			var current_line: int = nl_count + 1
			# 按行去重：同一行出现多次匹配只记录一次
			if not hit_flags.has(current_line):
				hit_flags[current_line] = true
				hits.append(current_line)
				if p_budget > 0 and hits.size() >= p_budget:
					break
			
			pos = found + search_len
		else:
			pos = found + 1  # 跳过，继续往后搜
	
	scan_result["lines"] = hits
	return scan_result


# 判断匹配位置是否构成词边界（前后都不是字母/数字/下划线）
# [param p_match_start]: 匹配起始下标
# [param p_match_end]: 匹配结束下标（不含）
func _is_word_boundary(p_content: String, p_match_start: int, p_match_end: int) -> bool:
	if p_match_start > 0 and _is_word_char(p_content[p_match_start - 1]):
		return false
	if p_match_end < p_content.length() and _is_word_char(p_content[p_match_end]):
		return false
	
	return true


# 判断字符是否为单词字符（字母、数字、下划线）
func _is_word_char(p_char: String) -> bool:
	if p_char.length() != 1:
		return false
	var c: int = p_char.unicode_at(0)
	return (c >= 0x30 and c <= 0x39) \
		or (c >= 0x41 and c <= 0x5A) \
		or (c >= 0x61 and c <= 0x7A) \
		or c == 0x5F


func _truncate(p_text: String, p_max_len: int = 60) -> String:
	if p_text.length() <= p_max_len:
		return p_text
	return p_text.substr(0, p_max_len) + "..."
