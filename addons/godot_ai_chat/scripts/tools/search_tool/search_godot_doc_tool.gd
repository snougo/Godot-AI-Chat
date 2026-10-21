@tool
extends AiTool

## 本地 Godot 离线文档标题搜索工具。
##
## 数据来源：`res://godot_doc`（官方离线 HTML 文档经转换工具转成 Markdown 后放置于此）。
## 本工具不再查询 ClassDB，仅对**文档标题**（文件名去掉扩展名）做模糊匹配，
## 返回匹配到的文档路径，供 AI 用 `read_file` 打开查看完整 API 说明。


# --- Constants ---

## 本地 Godot 离线文档根目录
const LOCAL_DOC_PATH: String = "res://godot_doc"

## 离线文档转换工具仓库地址（文档缺失时提示用户使用）
const DOC_CONVERSION_REPO_URL: String = "https://github.com/snougo/Godot-Doc-Conversion-Utils"

## 参与搜索的文档扩展名
const DOC_EXTENSIONS: Array[String] = ["md", "txt"]

## 单个关键词最多展示的匹配条数
const MAX_RESULTS_PER_KEYWORD: int = 20


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "search_godot_doc"
	tool_description = "Searches the local Godot offline documentation (`res://godot_doc`) by fuzzy document title."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"keyword": {
				"type": "string",
				"description": "Search keyword(s), matched fuzzily against document titles (file names), case-insensitive. E.g. `Node2D`, `animationplayer`. Separated by spaces or commas, each keyword is searched separately. `ClassName.member` tries the full string first, then falls back to the `ClassName` part."
			}
		},
		"required": ["keyword"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var keywords_list: PackedStringArray = _parse_keywords(p_args.get("keyword", ""))
	if keywords_list.is_empty():
		return ToolResult.fail("Error: Keywords cannot be empty.")
	
	# 收集本地文档；目录不存在或为空时直接告知并提示转换工具
	var doc_files: Array[String] = []
	_collect_doc_files(LOCAL_DOC_PATH, doc_files)
	if doc_files.is_empty():
		return ToolResult.fail(_build_missing_docs_message())
	doc_files.sort()
	
	var parts: PackedStringArray = PackedStringArray()
	parts.append("Local docs: `%s` (%d documents)" % [LOCAL_DOC_PATH, doc_files.size()])
	
	var match_count: int = 0
	for kw in keywords_list:
		var matches: Array[String] = _search_doc_titles(doc_files, kw)
		match_count += matches.size()
		parts.append(_format_matches(kw, matches))
	
	if match_count == 0:
		parts.append("No document title matched. This tool matches **document titles only** (file names), not class members. Try a shorter keyword, or look up online docs with `search_web` / `fetch_web_content`.")
	else:
		parts.append("Use `read_file` on a matched path to get the full documentation (description, signatures, parameters, code samples).")
	
	return ToolResult.ok("\n\n".join(parts))


# --- Private Functions: Parsing ---

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


# --- Private Functions: Title Search ---

# 递归收集指定扩展名的文档文件
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


# 提取文档标题：文件名去扩展名、转小写、去掉 `class_` 前缀
func _extract_doc_title(p_path: String) -> String:
	return p_path.get_file().get_basename().to_lower().trim_prefix("class_")


# 去除分隔符，用于忽略下划线/连字符/空格的差异（如 `input_event` 与 `inputevent`）
func _strip_separators(p_text: String) -> String:
	return p_text.replace("_", "").replace("-", "").replace(" ", "")


# --- Private Functions: Formatting ---

# 格式化单个关键词的匹配结果
func _format_matches(p_keyword: String, p_matches: Array[String]) -> String:
	if p_matches.is_empty():
		return "## `%s` — no title match" % p_keyword
	
	var lines: PackedStringArray = PackedStringArray()
	lines.append("## `%s` — %d match(es)" % [p_keyword, p_matches.size()])
	
	var limit: int = mini(p_matches.size(), MAX_RESULTS_PER_KEYWORD)
	for i in range(limit):
		lines.append("- `%s`" % p_matches[i])
	if p_matches.size() > limit:
		lines.append("- ... (%d more)" % (p_matches.size() - limit))
	
	return "\n".join(lines)


# 构建「本地文档缺失/为空」的提示信息
func _build_missing_docs_message() -> String:
	var reason: String = "does not exist"
	if DirAccess.dir_exists_absolute(LOCAL_DOC_PATH):
		reason = "exists but contains no documents"
	
	var lines: PackedStringArray = PackedStringArray()
	lines.append("Local Godot documentation unavailable: `%s` %s." % [LOCAL_DOC_PATH, reason])
	lines.append("This tool fuzzy-searches the **titles** of the local offline documentation only, so the search could not be performed.")
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
