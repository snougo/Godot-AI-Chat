@tool
extends AiTool

## 列出文件夹结构工具。
## - 递归展开完整目录树；
## - 目标目录（根）及其前 depth 层子目录的直接文件完整列出文件名；
## - 其余目录的直接文件以 "N files in this folder" 计数形式显示；
## - 排除 godot_doc 目录（专供 search_godot_api 使用，与项目无关）。


# --- Constants ---

const EXCLUDED_DIR_NAMES: PackedStringArray = ["godot_doc"]

## 允许的最大文件名展开深度上限（防止整棵树全展开导致输出过大）
const MAX_LIST_FILES_DEPTH: int = 5


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "list_folder"
	tool_description = "Lists a folder's full directory tree."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Folder path to list."
			},
			"depth": {
				"type": "integer",
				"description": "Subdirectory levels below the target that list file names. Deeper levels show a file count. 0 = only the target folder lists its files. Directory structure is always fully expanded.",
				"minimum": 0,
				"maximum": 5,
				"default": 0
			}
		},
		"required": ["path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var path: String = p_args.get("path", "")
	if path.is_empty():
		return ToolResult.fail("Error: 'path' parameter is required.")
	
	var dir := DirAccess.open(path)
	if dir == null:
		return ToolResult.fail("Error: Failed to access directory: " + path)
	
	# 解析列名深度：clamp 防越界，depth=0 即为原行为（仅根目录列名）
	var list_files_depth: int = int(p_args.get("depth", 0))
	list_files_depth = clampi(list_files_depth, 0, MAX_LIST_FILES_DEPTH)
	
	var root_name: String = path.get_file()
	if root_name.is_empty():
		root_name = path.trim_suffix("/")
	
	var md: String = "Context for Folder: `%s`\n\n" % path
	md += "Folder File Structure:\n```\n"
	md += "%s/\n" % root_name
	md += _build_folder_tree(path, "  ", list_files_depth)
	md += "```\n"
	return ToolResult.ok(md)


# --- Private Functions ---

# 构建目录树文本。
# p_list_files_depth >= 0: 本层直接文件逐个列名（目标根目录及其前 N 层子目录）
# p_list_files_depth < 0:  本层直接文件以计数形式汇总，但仍递归展开子目录骨架
# [性能] 旧实现用 result += ... 在每个条目上拼接，GDScript 的 String += 会复制整个
# 已累积字符串（O(n²)）。目录树输出可达数百 KB，改为 PackedStringArray 收集后一次 join。
func _build_folder_tree(p_path: String, p_indent: String, p_list_files_depth: int) -> String:
	var dir := DirAccess.open(p_path)
	if not dir:
		return ""
	
	var subdirs: Array[String] = []
	for item in dir.get_directories():
		if item == "." or item == "..":
			continue
		if EXCLUDED_DIR_NAMES.has(item):
			continue
		subdirs.append(item)
	
	var files: Array[String] = []
	for item in dir.get_files():
		files.append(item)
	
	# 文件条目数：列名层逐个列出，计数层汇总为一个计数条目
	var file_entry_count: int = 0
	if p_list_files_depth >= 0:
		file_entry_count = files.size()
	elif not files.is_empty():
		file_entry_count = 1
	
	var total_entries: int = subdirs.size() + file_entry_count
	if total_entries == 0:
		return p_indent + "(empty)\n"
	
	var parts: PackedStringArray = PackedStringArray()
	var entry_index: int = 0
	
	# 先输出子目录（递归展开，列名深度随之递减）
	for i in range(subdirs.size()):
		var sub: String = subdirs[i]
		var is_last: bool = (entry_index == total_entries - 1)
		var prefix: String = "└─ " if is_last else "├─ "
		var sub_path: String = p_path.path_join(sub)
		parts.append(p_indent + prefix + sub + "/\n")
		parts.append(_build_folder_tree(sub_path, p_indent + ("   " if is_last else "│  "), p_list_files_depth - 1))
		entry_index += 1
	
	# 再输出文件：列名层逐行列名，计数层显示汇总
	if p_list_files_depth >= 0:
		for i in range(files.size()):
			var is_last: bool = (entry_index == total_entries - 1)
			var prefix: String = "└─ " if is_last else "├─ "
			parts.append(p_indent + prefix + files[i] + "\n")
			entry_index += 1
	elif not files.is_empty():
		parts.append(p_indent + "└─ %d files in this folder\n" % files.size())
	
	return "".join(parts)
