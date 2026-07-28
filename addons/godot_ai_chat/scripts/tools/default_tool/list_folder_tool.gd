@tool
extends AiTool

## 列出文件夹结构工具。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "list_folder"
	tool_description = "Lists the structure and contents of a folder/directory."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The folder path to list."
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
	
	var md: String = "Context for Folder: `%s`\n\n" % path
	md += "Folder File Structure:\n```\n"
	md += "%s/\n" % path.get_file()
	md += _build_folder_tree(path, "  ")
	md += "```\n"
	return ToolResult.ok(md)


# --- Private Functions ---

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
