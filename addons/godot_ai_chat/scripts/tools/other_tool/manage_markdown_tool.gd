@tool
extends AiTool

## 允许操作的文件扩展名白名单
const ALLOWED_EXTENSIONS: Array[String] = ["md"]

func _init() -> void:
	tool_name = "manage_markdown"
	tool_description = "Manage Markdown files. Requires a directory path and a file name."


## 定义工具的参数结构
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"operation": {
				"type": "string",
				"enum": ["create", "append", "overwrite", "read"],
				"description": "The operation to perform: 'create', 'append', 'overwrite', or 'read'."
			},
			"path": {
				"type": "string",
				"description": "The directory path starting with 'res://' (e.g., 'res://target_directory_path/')."
			},
			"file_name": {
				"type": "string",
				"description": "The file name with extension (e.g., 'notes.md')."
			},
			"content": {
				"type": "string",
				"description": "The text content. Required for 'create', 'append', and 'overwrite'. Ignored for 'read'."
			}
		},
		"required": ["operation", "path", "file_name"]
	}


## 执行工具的主要逻辑
func execute(_args: Dictionary) -> Dictionary:
	var operation: String = _args.get("operation", "read")
	var folder_path: String = _args.get("path", "")
	var file_name: String = _args.get("file_name", "")
	var content: String = _args.get("content", "")
	
	# 1. 参数基础验证
	if folder_path.is_empty() or file_name.is_empty():
		return {"success": false, "data": "Error: Both 'path' (directory) and 'file_name' are required."}
	
	# 2. 构建完整路径
	# 确保目录路径以 "/" 结尾
	if not folder_path.ends_with("/"):
		folder_path += "/"
	
	var full_path: String = folder_path + file_name
	
	# 3. 安全性检查
	# 调用基类验证路径安全性（黑名单检查等）
	var safety_error: String = validate_path_safety(full_path)
	if not safety_error.is_empty():
		return {"success": false, "data": safety_error}
	
	# 检查文件扩展名是否在白名单中
	var ext: String = full_path.get_extension().to_lower()
	if not ext in ALLOWED_EXTENSIONS:
		return {"success": false, "data": "Security Error: Only %s files are allowed." % str(ALLOWED_EXTENSIONS)}
	
	# 4. 执行具体文件操作
	var file: FileAccess
	
	match operation:
		"create":
			# 创建模式：文件不能已存在
			if FileAccess.file_exists(full_path):
				return {"success": false, "data": "Error: File already exists at " + full_path + ". Use 'overwrite' or 'append'."}
			
			# 确保目标目录存在
			if not DirAccess.dir_exists_absolute(folder_path):
				var err: Error = DirAccess.make_dir_recursive_absolute(folder_path)
				if err != OK:
					return {"success": false, "data": "Failed to create directory: " + folder_path}
			
			file = FileAccess.open(full_path, FileAccess.WRITE)
			if file == null:
				return {"success": false, "data": "Failed to create file: " + str(FileAccess.get_open_error())}
			
			file.store_string(content)
			file.close()
			ToolBox.refresh_editor_filesystem()
			return {"success": true, "data": "File created successfully: " + full_path}
		
		"append":
			# 追加模式：文件必须存在
			if not FileAccess.file_exists(full_path):
				return {"success": false, "data": "Error: File does not exist at " + full_path + ". Use 'create' first."}
				
			file = FileAccess.open(full_path, FileAccess.READ_WRITE)
			if file == null:
				return {"success": false, "data": "Failed to open file for appending: " + str(FileAccess.get_open_error())}
			
			file.seek_end()
			# 智能换行：如果文件非空，在追加内容前添加换行符
			if file.get_length() > 0:
				file.store_string("\n")
			
			file.store_string(content)
			file.close()
			ToolBox.refresh_editor_filesystem()
			return {"success": true, "data": "Content appended to " + full_path}
		
		"overwrite":
			# 覆盖模式：若目录不存在则自动创建
			if not DirAccess.dir_exists_absolute(folder_path):
				var err: Error = DirAccess.make_dir_recursive_absolute(folder_path)
				if err != OK:
					return {"success": false, "data": "Failed to create directory: " + folder_path}
			
			file = FileAccess.open(full_path, FileAccess.WRITE)
			if file == null:
				return {"success": false, "data": "Failed to open file for writing: " + str(FileAccess.get_open_error())}
			
			file.store_string(content)
			file.close()
			ToolBox.refresh_editor_filesystem()
			return {"success": true, "data": "File overwritten: " + full_path}
		
		"read":
			# 读取模式
			if not FileAccess.file_exists(full_path):
				return {"success": false, "data": "Error: File does not exist at " + full_path}
			
			file = FileAccess.open(full_path, FileAccess.READ)
			if file == null:
				return {"success": false, "data": "Failed to open file for reading: " + str(FileAccess.get_open_error())}
			
			var text: String = file.get_as_text()
			file.close()
			return {"success": true, "data": text}
		
		_:
			return {"success": false, "data": "Error: Unknown operation '" + operation + "'."}
