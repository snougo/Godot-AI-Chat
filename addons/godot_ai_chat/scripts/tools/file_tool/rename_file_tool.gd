@tool
extends AiTool

## 重命名单一文件。
## 注意：仅允许更改文件名，不允许跨目录移动。如需移动文件，请使用 move_file 工具。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "rename_file"
	tool_description = "Renames a single file."
	security_level = SecurityLevel.PATH_VALIDATED


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"source_path": {
				"type": "string",
				"description": "The full source file path to rename, starting with 'res://'."
			},
			"new_name": {
				"type": "string",
				"description": "The new filename."
			}
		},
		"required": ["source_path", "new_name"]
	}


## 执行文件重命名操作
func execute(p_args: Dictionary) -> ToolResult:
	var source_path: String = p_args.get("source_path", "")
	var new_name: String = p_args.get("new_name", "")
	
	if source_path.is_empty() or new_name.is_empty():
		return ToolResult.fail("Error: Both source_path and new_name are required.")
	
	# 验证源路径安全性
	var safety_err: String = validate_path_safety(source_path)
	if not safety_err.is_empty():
		return ToolResult.fail(safety_err)
	
	# 拒绝操作目录
	if DirAccess.dir_exists_absolute(source_path):
		return ToolResult.fail("Error: '%s' is a directory. Cannot rename directories." % source_path)
	
	# 源文件必须存在
	if not FileAccess.file_exists(source_path):
		return ToolResult.fail("Error: Source file not found at " + source_path)
	
	# 校验 new_name：不能包含路径分隔符
	if "/" in new_name or "\\" in new_name:
		return ToolResult.fail("Error: new_name must be a filename only, without any path components.")
	
	# 校验 new_name：不能为空
	if new_name.is_empty():
		return ToolResult.fail("Error: new_name cannot be empty.")
	
	# 校验 new_name：必须与原名不同
	var current_filename: String = source_path.get_file()
	if new_name == current_filename:
		return ToolResult.fail("Error: new_name is identical to the current filename '%s'." % current_filename)
	
	# 构建目标路径（同一目录 + 新文件名）
	var target_path: String = source_path.get_base_dir().path_join(new_name)
	
	# 目标路径不可已存在
	if FileAccess.file_exists(target_path) or DirAccess.dir_exists_absolute(target_path):
		return ToolResult.fail("Error: Target already exists at " + target_path)
	
	# 执行重命名
	var err: Error = DirAccess.rename_absolute(source_path, target_path)
	if err != OK:
		return ToolResult.fail("Failed to rename. Error code: " + str(err))
	
	ToolBox.refresh_editor_filesystem()
	return ToolResult.ok("Successfully renamed '%s' to '%s'." % [source_path, target_path])
