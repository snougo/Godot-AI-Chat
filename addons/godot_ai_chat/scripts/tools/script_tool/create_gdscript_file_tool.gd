@tool
extends AiTool

## 脚本文件创建工具。
## 只能创建 GDScript(.gd) 文件，用于 Script Editor 技能。
## 注意：目标文件夹必须已存在，不会自动创建。


# --- Constants ---

## 允许的脚本扩展名
const SCRIPT_EXTENSIONS: Array[String] = ["gd"]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_gdscript_file"
	tool_description = "Creates a new GDScript (.gd) file."
	security_level = SecurityLevel.PATH_VALIDATED


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Target folder path (e.g., 'res://xxx/'). The folder must already exist."
			},
			"file_name": {
				"type": "string",
				"description": "File name with .gd extension (e.g., 'my_script.gd')."
			},
			"content": {
				"type": "string",
				"description": "Initial script content."
			}
		},
		"required": ["path", "file_name", "content"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var folder_path: String = p_args.get("path", "")
	var file_name: String = p_args.get("file_name", "")
	var content: String = p_args.get("content", "")
	
	if folder_path.is_empty() or file_name.is_empty() or content.is_empty():
		return ToolResult.fail("Error: 'path', 'file_name', and 'content' are required.")
	
	# 确保文件夹路径以 / 结尾
	if not folder_path.ends_with("/"):
		folder_path += "/"
	
	var full_path: String = folder_path + file_name
	
	# 安全校验
	var safety_err: String = validate_path_safety(full_path)
	if not safety_err.is_empty():
		return ToolResult.fail(safety_err)
	
	# 检查文件是否已存在
	if FileAccess.file_exists(full_path):
		return ToolResult.fail("Error: File already exists at %s. Overwriting is not allowed." % full_path)
	
	# 检查目标文件夹是否存在（禁止越权创建文件夹）
	if not DirAccess.dir_exists_absolute(folder_path):
		return ToolResult.fail("Error: Target folder '%s' does not exist. Use `manage_folder` to create it first." % folder_path)
	
	# 强制校验扩展名
	var ext: String = full_path.get_extension().to_lower()
	if ext not in SCRIPT_EXTENSIONS:
		return ToolResult.fail("Error: Invalid extension '.%s'. Script files must use: .gd." % ext)
	
	var file := FileAccess.open(full_path, FileAccess.WRITE)
	if not file:
		return ToolResult.fail("Failed to create script file: " + str(FileAccess.get_open_error()))
	
	file.store_string(content)
	file.close()
	
	ToolBox.update_editor_filesystem(full_path)
	return ToolResult.ok("Script created: %s" % full_path)
