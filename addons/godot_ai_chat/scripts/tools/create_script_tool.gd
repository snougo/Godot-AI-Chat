@tool
extends AiTool

# 定义允许的扩展名白名单，防止创建恶意文件
const ALLOWED_EXTENSIONS = ["gd", "gdshader"]


func _init() -> void:
	name = "create_script"
	description = "Create a new `.gd` or `.gdshader` file. By default, it will not overwrite existing files. Only supports res:// paths."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The target file path, must be current workspace path."
			},
			"content": {
				"type": "string",
				"description": "The content to write."
			},
			"overwrite": {
				"type": "boolean",
				"description": "Whether to overwrite the file if it already exists. Default is false."
			}
		},
		"required": ["path", "content"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path: String = _args.get("path", "")
	var content: String = _args.get("content", "")
	var overwrite: bool = _args.get("overwrite", false)
	
	# 1. 基础路径校验
	if path.is_empty():
		return {"success": false, "data": "Error: 'path' is required."}
	if not path.begins_with("res://"):
		return {"success": false, "data": "Error: Path must start with 'res://'."}
	
	# 2. 安全性检查：禁止路径遍历和敏感目录写入
	if ".." in path:
		return {"success": false, "data": "Error: Path traversal ('..') is not allowed."}
	if "/.git/" in path or "/.import/" in path:
		return {"success": false, "data": "Error: Writing to hidden/system directories is not allowed."}
	
	# 3. 扩展名白名单检查
	var extension = path.get_extension().to_lower()
	if extension not in ALLOWED_EXTENSIONS:
		return {"success": false, "data": "Error: File extension '%s' is not allowed. Allowed: %s" % [extension, ALLOWED_EXTENSIONS]}
	
	# 4. 防止意外覆盖
	if FileAccess.file_exists(path) and not overwrite:
		return {"success": false, "data": "Error: File '%s' already exists. Set 'overwrite' to true if you intend to replace it." % path}
	
	# 5. 自动创建目录
	var base_dir = path.get_base_dir()
	var dir_access = DirAccess.open("res://")
	if not dir_access.dir_exists(base_dir):
		var err = dir_access.make_dir_recursive(base_dir)
		if err != OK:
			return {"success": false, "data": "Error: Failed to create directory " + base_dir}
	
	# 6. 写入文件
	var file = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "data": "Error: Failed to open file: " + str(FileAccess.get_open_error())}
	
	file.store_string(content)
	file.close()
	
	# 7. 刷新编辑器资源系统
	if Engine.is_editor_hint():
		var fs = EditorInterface.get_resource_filesystem()
		if fs:
			fs.scan()
	
	return {"success": true, "data": "File created successfully at: " + path}
