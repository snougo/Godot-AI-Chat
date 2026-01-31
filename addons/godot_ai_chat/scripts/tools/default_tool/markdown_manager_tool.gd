@tool
extends AiTool

## 管理 Markdown 文件。
## 支持创建（带覆盖保护）和读取操作。

# --- Enums / Constants ---

## 允许操作的文件扩展名白名单
const ALLOWED_EXTENSIONS: Array[String] = ["md"]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "markdown_manager"
	tool_description = "Manage GENERIC Markdown files. Do NOT use this for 'TODO.md'; use 'todo_list' instead."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"operation": {
				"type": "string",
				"enum": ["create", "read"],
				"description": "The operation to perform: 'create' or 'read'."
			},
			"path": {
				"type": "string",
				"description": "The full path starting with 'res://' ."
			},
			"file_name": {
				"type": "string",
				"description": "The file name with extension (e.g., 'notes.md')."
			},
			"content": {
				"type": "string",
				"description": "The text content. Required for 'create'. Ignored for 'read'."
			}
		},
		"required": ["operation", "path", "file_name"]
	}


## 执行 Markdown 文件管理操作
## [param p_args]: 包含 operation、path、file_name 和 content 的参数字典
## [return]: 包含成功状态和操作结果的字典
func execute(p_args: Dictionary) -> Dictionary:
	var operation: String = p_args.get("operation", "read")
	var folder_path: String = p_args.get("path", "")
	var file_name: String = p_args.get("file_name", "")
	var content: String = p_args.get("content", "")
	
	if folder_path.is_empty() or file_name.is_empty():
		return {"success": false, "data": "Error: Both 'path' (directory) and 'file_name' are required."}
	
	folder_path = _ensure_trailing_slash(folder_path)
	var full_path: String = folder_path + file_name
	
	var validation_result: Dictionary = _validate_extension(full_path)
	if not validation_result.get("success", false):
		return validation_result
	
	match operation:
		"create":
			return _create_file(full_path, folder_path, content)
		"read":
			return _read_file(full_path)
		_:
			return {"success": false, "data": "Error: Unknown operation '" + operation + "'. Allowed: 'create', 'read'."}


# --- Private Functions ---

## 确保目录路径以斜杠结尾
## [param p_path]: 目录路径
## [return]: 标准化后的目录路径
func _ensure_trailing_slash(p_path: String) -> String:
	if not p_path.ends_with("/"):
		return p_path + "/"
	return p_path


## 验证文件扩展名
## [param p_full_path]: 完整文件路径
## [return]: 验证结果字典
func _validate_extension(p_full_path: String) -> Dictionary:
	var ext: String = p_full_path.get_extension().to_lower()
	if ext not in ALLOWED_EXTENSIONS:
		return {"success": false, "data": "Security Error: Only %s files are allowed." % str(ALLOWED_EXTENSIONS)}
	
	return {"success": true}


## 创建新文件（带覆盖保护）
## [param p_full_path]: 完整文件路径
## [param p_folder_path]: 目录路径
## [param p_content]: 文件内容
## [return]: 操作结果字典
func _create_file(p_full_path: String, p_folder_path: String, p_content: String) -> Dictionary:
	if FileAccess.file_exists(p_full_path):
		return {"success": false, "data": "Error: File already exists at " + p_full_path + ". Overwriting is not allowed."}
	
	if not DirAccess.dir_exists_absolute(p_folder_path):
		var err: Error = DirAccess.make_dir_recursive_absolute(p_folder_path)
		if err != OK:
			return {"success": false, "data": "Failed to create directory: " + p_folder_path}
	
	var file: FileAccess = FileAccess.open(p_full_path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "data": "Failed to create file: " + str(FileAccess.get_open_error())}
	
	file.store_string(p_content)
	file.close()
	ToolBox.refresh_editor_filesystem()
	return {"success": true, "data": "File created successfully: " + p_full_path}


## 读取文件内容
## [param p_full_path]: 完整文件路径
## [return]: 操作结果字典
func _read_file(p_full_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_full_path):
		return {"success": false, "data": "Error: File does not exist at " + p_full_path}
	
	var file: FileAccess = FileAccess.open(p_full_path, FileAccess.READ)
	if file == null:
		return {"success": false, "data": "Failed to open file for reading: " + str(FileAccess.get_open_error())}
	
	var text: String = file.get_as_text()
	file.close()
	return {"success": true, "data": text}
