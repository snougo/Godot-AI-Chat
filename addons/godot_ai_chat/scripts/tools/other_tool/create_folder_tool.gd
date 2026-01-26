@tool
extends AiTool

## 在指定路径创建新文件夹（目录）。
## 支持创建嵌套目录（例如：res://a/b/c）。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_folder"
	tool_description = "Create a new folder (directory) at the specified path. Support creating nested directories (e.g., res://a/b/c)."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path where the folder (directory) should be created."
			}
		},
		"required": ["path"]
	}


## 执行文件夹创建操作
## [param p_args]: 包含 path 的参数字典
## [return]: 包含成功状态和操作结果的字典
func execute(p_args: Dictionary) -> Dictionary:
	var path: String = p_args.get("path", "")
	
	if path.is_empty():
		return {"success": false, "data": "Error: 'path' parameter is required."}
	
	path = _normalize_path(path)
	
	var security_error: String = validate_path_safety(path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	return _create_folder(path)


# --- Private Functions ---

## 标准化路径格式
## [param p_path]: 原始路径
## [return]: 标准化后的路径
func _normalize_path(p_path: String) -> String:
	var normalized: String = p_path.replace("\\", "/")
	if normalized.ends_with("/"):
		normalized = normalized.left(-1)
	return normalized


## 创建文件夹
## [param p_path]: 要创建的文件夹路径
## [return]: 操作结果字典
func _create_folder(p_path: String) -> Dictionary:
	var dir: DirAccess = DirAccess.open("res://")
	if dir == null:
		return {"success": false, "data": "Failed to access file system."}
	
	if dir.dir_exists(p_path):
		return {"success": true, "data": "Folder already exists: %s" % p_path}
	
	var err: Error = dir.make_dir_recursive(p_path)
	if err == OK:
		# ToolBox为全局静态工具
		ToolBox.refresh_editor_filesystem()
		return {"success": true, "data": "Successfully created folder: %s" % p_path}
	else:
		return {"success": false, "data": "Failed to create folder. Error code: %s" % str(err)}
