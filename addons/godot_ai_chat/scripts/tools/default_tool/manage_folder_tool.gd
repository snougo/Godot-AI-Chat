@tool
extends AiTool

## 文件夹综合管理工具。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "manage_folder"
	tool_description = "Lists and creates folders and directories."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["list", "create"],
				"description": "The operation to perform: 'list' to view folder structure, 'create' to create a new folder."
			},
			"path": {
				"type": "string",
				"description": "The folder path. Required for actions 'list' and 'create'."
			}
		},
		"required": ["action"]
	}


## 执行文件夹操作
## [param p_args]: 包含 action 及相关参数的字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> ToolResult:
	var action: String = p_args.get("action", "")
	
	match action:
		"list":
			return _handle_list(p_args)
		"create":
			return _handle_create(p_args)
		_:
			return ToolResult.fail("Error: Unknown action '%s'. Valid actions: list, create." % action)


# --- Private Functions ---

# 处理文件夹结构列出操作
func _handle_list(p_args: Dictionary) -> ToolResult:
	var path: String = p_args.get("path", "")
	if path.is_empty():
		return ToolResult.fail("Error: 'path' parameter is required for action 'list'.")
	
	var dir := DirAccess.open(path)
	if dir == null:
		return ToolResult.fail("Error: Failed to access directory: " + path)
	
	var md: String = "Context for Folder: `%s`\n\n" % path
	md += "Folder File Structure:\n```\n"
	md += "%s/\n" % path.get_file()
	md += _build_folder_tree(path, "  ")
	md += "```\n"
	return ToolResult.ok(md)


# 处理文件夹创建操作
func _handle_create(p_args: Dictionary) -> ToolResult:
	var path: String = p_args.get("path", "")
	if path.is_empty():
		return ToolResult.fail("Error: 'path' parameter is required for action 'create'.")
	
	path = _normalize_path(path)
	
	var security_error: String = validate_path_safety(path)
	if not security_error.is_empty():
		return ToolResult.fail(security_error)
	
	var dir := DirAccess.open("res://")
	if dir == null:
		return ToolResult.fail("Error: Failed to access file system.")
	
	if dir.dir_exists(path):
		return ToolResult.fail("Error: Folder already exists: %s" % path)
	
	var err: Error = dir.make_dir_recursive(path)
	if err == OK:
		ToolBox.refresh_editor_filesystem()
		return ToolResult.ok("Successfully created folder: %s" % path)
	else:
		return ToolResult.fail("Error: Failed to create folder. Error code: %s" % str(err))


# === Utility Functions ===

# 递归构建文件夹树
static func _build_folder_tree(p_path: String, p_indent: String) -> String:
	var result: String = ""
	var dir := DirAccess.open(p_path)
	if not dir:
		return ""
	
	var subdirs: Array = []
	for item in dir.get_directories():
		if item != "." and item != "..":
			subdirs.append(item)
	
	var files: Array = []
	for item in dir.get_files():
		files.append(item)
	
	var all_items: Array = subdirs + files
	for i in range(all_items.size()):
		var item = all_items[i]
		var is_last: bool = (i == all_items.size() - 1)
		var prefix: String = "└─ " if is_last else "├─ "
		var item_path: String = p_path.path_join(item)
		
		if item in subdirs:
			result += p_indent + prefix + item + "/\n"
			result += _build_folder_tree(item_path, p_indent + ("   " if is_last else "│  "))
		else:
			result += p_indent + prefix + item + "\n"
	return result


# 标准化路径格式
func _normalize_path(p_path: String) -> String:
	var normalized: String = p_path.replace("\\", "/")
	if normalized.ends_with("/"):
		normalized = normalized.left(-1)
	return normalized
