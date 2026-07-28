@tool
extends AiTool

## 创建文件夹工具。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_folder"
	tool_description = "Creates a new folder/directory."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The folder path to create."
			}
		},
		"required": ["path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var path: String = p_args.get("path", "")
	if path.is_empty():
		return ToolResult.fail("Error: 'path' parameter is required.")
	
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


# --- Private Functions ---

func _normalize_path(p_path: String) -> String:
	var normalized: String = p_path.replace("\\", "/")
	if normalized.ends_with("/"):
		normalized = normalized.left(-1)
	return normalized
