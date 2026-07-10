@tool
extends AiTool

## 跨文件批量搜索工具（相当于 grep）。
## 在指定文件夹内搜索所有脚本，找出包含/不包含指定代码内容的文件。
##
## 使用场景：
## - 规范性检查：检查指定范围内的脚本是否都实现了某个函数或者是否使用了某个公共变量
## - 重构影响分析：找出哪些文件引用了即将废弃的 API
## - 代码审计：查找项目中的危险模式或重复代码


# --- Constants ---

## 搜索的文件扩展名（开发者可按需修改此常量）
const SEARCH_EXTENSIONS: Array[String] = ["gd"]

## 单个文件大小上限（超过此大小的文件跳过，防止大文件卡死）
const MAX_FILE_SIZE: int = 1024 * 1024  # 1 MB

## 最大搜索文件数（防止文件夹过大导致超时）
const MAX_FILES: int = 200


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "grep_code"
	tool_description = "Searches all script files in a folder for specific code text and reports matches with line numbers."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The folder path to search. Scans recursively."
			},
			"search": {
				"type": "string",
				"description": "The code text to search for. Matching is exact and case-sensitive. Single-line search only."
			}
		},
		"required": ["path", "search"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var path: String = p_args.get("path", "")
	var search: String = p_args.get("search", "")
	
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
	
	# --- 收集文件 ---
	var all_files: Array[String] = []
	_collect_scripts(path, all_files)
	
	if all_files.is_empty():
		return ToolResult.fail("Error: No script files found in: " + path)
	
	if all_files.size() > MAX_FILES:
		return ToolResult.fail("Error: Too many files (%d) in folder. Maximum is %d. Please search a narrower folder." % [all_files.size(), MAX_FILES])
	
	# --- 依次搜索 ---
	var search_len := search.length()
	
	var match_files: Array[Dictionary] = []
	
	for file_path in all_files:
		var result := _search_in_file(file_path, search, search_len)
		if not result.is_empty():
			match_files.append({"path": file_path, "lines": result})
	
	# --- 构建返回 ---
	var file_count := all_files.size()
	var search_preview := _truncate(search)
	
	var msg: String = "Grep result for \"%s\" in `%s`:\n" % [search_preview, path]
	msg += "  Scanned: %d files (%s)\n" % [file_count, ", ".join(SEARCH_EXTENSIONS)]
	msg += "  Matches: %d files\n\n" % [match_files.size()]
	
	if match_files.is_empty():
		msg += "── No matches found ──\n"
		return ToolResult.ok(msg)
	
	# 完整展示所有匹配项目，不截断
	msg += "── Matches ──\n"
	for m in match_files:
		msg += "%s\n" % m["path"]
		for line in m["lines"]:
			msg += "  Line %d\n" % line
		msg += "\n"
	
	return ToolResult.ok(msg)


# --- Private Functions ---

# 递归收集指定扩展名的脚本文件
func _collect_scripts(p_folder: String, p_results: Array[String]) -> void:
	var dir: DirAccess = DirAccess.open(p_folder)
	if not dir:
		return
	
	dir.list_dir_begin()
	var name: String = dir.get_next()
	
	while name != "":
		if name == "." or name == "..":
			name = dir.get_next()
			continue
		
		var full_path := p_folder.path_join(name)
		
		if dir.current_is_dir():
			_collect_scripts(full_path, p_results)  # 始终递归
		else:
			var ext: String = name.get_extension().to_lower()
			if ext in SEARCH_EXTENSIONS:
				p_results.append(full_path)
		
		name = dir.get_next()
	
	dir.list_dir_end()


# 在单个文件中搜索，返回匹配行号列表（1-based）
# 返回空数组表示无匹配
func _search_in_file(p_path: String, p_search: String, p_search_len: int) -> Array[int]:
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not is_instance_valid(file):
		return []
	
	# 检查文件大小
	if file.get_length() > MAX_FILE_SIZE:
		file.close()
		return []
	
	var content: String = file.get_as_text()
	file.close()
	
	# 统一换行符
	content = content.replace("\r\n", "\n").replace("\r", "\n")
	
	# 搜索
	var results: Array[int] = []
	var pos: int = 0
	
	while pos < content.length():
		var found := content.find(p_search, pos)
		if found == -1:
			break
		
		# 词边界检查：防止匹配到标识符的子串（如 class_name 匹配到 global_class_name）
		if _is_word_boundary(content, found, p_search_len):
			# 字符位置 → 1-based 行号
			var line_num := 1
			for i in range(found):
				if content[i] == "\n":
					line_num += 1
			results.append(line_num)
			pos = found + p_search_len
		else:
			pos = found + 1  # 跳过，继续往后搜
	
	return results


# 检查匹配位置是否为词边界
# 匹配前后都不是字母、数字、下划线时返回 true
static func _is_word_boundary(p_content: String, p_match_pos: int, p_match_len: int) -> bool:
	# 检查匹配前一个字符
	if p_match_pos > 0:
		if _is_word_char(p_content[p_match_pos - 1]):
			return false
	
	# 检查匹配后一个字符
	var after_pos := p_match_pos + p_match_len
	if after_pos < p_content.length():
		if _is_word_char(p_content[after_pos]):
			return false
	
	return true


# 判断字符是否为单词字符（字母、数字、下划线）
static func _is_word_char(p_char: String) -> bool:
	if p_char.length() != 1:
		return false
	var c := p_char.unicode_at(0)
	return (c >= 0x30 and c <= 0x39) \
		or (c >= 0x41 and c <= 0x5A) \
		or (c >= 0x61 and c <= 0x7A) \
		or c == 0x5F


static func _truncate(p_text: String, p_max_len: int = 60) -> String:
	if p_text.length() <= p_max_len:
		return p_text
	return p_text.substr(0, p_max_len) + "..."
