@tool
extends AiTool

# 定义允许的扩展名白名单，防止创建恶意文件
const ALLOWED_EXTENSIONS = ["gd", "gdshader"]

# 定义路径黑名单（包含这些字符串的路径将被拒绝）
const PATH_BLACKLIST = [
	"/.git/", 
	"/.import/", 
	"/.godot/",
	"/android/", 
	"/addons/"
]

func _init() -> void:
	tool_name = "create_new_empty_script"
	tool_description = "Create a new empty `.gd` or `.gdshader` file."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The target file path (e.g., 'res://scripts/new_script.gd')."
			}
		},
		"required": ["path"]
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path: String = _args.get("path", "")
	# 强制内容为空，强制不覆盖
	var content: String = "" 
	
	# 基础路径校验
	if path.is_empty():
		return {"success": false, "data": "Error: 'path' is required."}
	if not path.begins_with("res://"):
		return {"success": false, "data": "Error: Path must start with 'res://'."}
	
	# 安全性检查：禁止路径遍历和敏感目录写入
	if ".." in path:
		return {"success": false, "data": "Error: Path traversal ('..') is not allowed."}
	
	for blocked_pattern in PATH_BLACKLIST:
		if blocked_pattern in path:
			return {
				"success": false, 
				"data": "Error: The path contains a blacklisted pattern '%s'. Creating scripts in this location is not allowed." % blocked_pattern
			}
	
	# 扩展名白名单检查
	var extension: String = path.get_extension().to_lower()
	if extension not in ALLOWED_EXTENSIONS:
		return {"success": false, "data": "Error: File extension '%s' is not allowed. Allowed: %s" % [extension, ALLOWED_EXTENSIONS]}
	
	# 防止覆盖 (核心约束)
	if FileAccess.file_exists(path):
		return {"success": false, "data": "Error: File '%s' already exists. To prevent accidental data loss, this tool cannot overwrite existing files." % path}
	
	# 自动创建目录
	var base_dir: String = path.get_base_dir()
	var dir_access: DirAccess = DirAccess.open("res://")
	if not dir_access.dir_exists(base_dir):
		var err: Error = dir_access.make_dir_recursive(base_dir)
		if err != OK:
			return {"success": false, "data": "Error: Failed to create directory " + base_dir}
	
	# 写入文件
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "data": "Error: Failed to open file: " + str(FileAccess.get_open_error())}
	
	file.store_string(content)
	file.close()
	
	# 刷新编辑器资源系统
	if Engine.is_editor_hint():
		var fs: EditorFileSystem = EditorInterface.get_resource_filesystem()
		if fs:
			fs.scan()
	
	return {"success": true, "data": "Empty file created successfully at: " + path}
