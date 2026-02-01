@tool
extends AiTool

## 创建通用 Markdown 文件工具
##
## 专用于创建新的 .md 文件。
## 严禁用于创建脚本文件！

# --- Enums / Constants ---

## 允许操作的文件扩展名白名单 (严格限制为 md)
const ALLOWED_EXTENSIONS: Array[String] = ["md"]

## 禁止操作的文件名黑名单 (大小写不敏感)
const RESTRICTED_FILES: Array[String] = [
	"todo",
	"memory"
]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_markdown"
	tool_description = "Creates A New Markdown File (.md ONLY)."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The folder path starting with 'res://'. NOT the full file path."
			},
			"file_name": {
				"type": "string",
				"description": "The file name WITHOUT extension. E.g. 'design_doc'. Do NOT include '.md' or '.gd'."
			},
			"file_format": {
				"type": "string",
				"enum": ["md"],
				"description": "The file format. ONLY 'md' is allowed here."
			},
			"content": {
				"type": "string",
				"description": "The Markdown text content."
			}
		},
		"required": ["path", "file_name", "file_format", "content"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var folder_path: String = p_args.get("path", "")
	var raw_file_name: String = p_args.get("file_name", "")
	var file_format: String = p_args.get("file_format", "md")
	var content: String = p_args.get("content", "")
	
	if folder_path.is_empty() or raw_file_name.is_empty() or content.is_empty():
		return {"success": false, "data": "Error: 'path', 'file_name', and 'content' are all required."}
	
	# [Check 1] 格式检查 (虽然 Schema 限制了，但为了健壮性再查一次)
	if file_format != "md":
		return {
			"success": false, 
			"data": "Error: Invalid format '%s'. This tool ONLY supports 'md'. Use 'create_script' for code files." % file_format
		}
	
	# [Check 2] 文件名清理 (防止模型还是传了 .md 或 .gd)
	# 如果用户传了 'script.gd'，这里会变成 'script'，最后变成 'script.md'
	# 这样即使模型想写脚本，也只会得到一个 Markdown 文件，不会污染项目逻辑
	var clean_file_name = raw_file_name.get_basename() 
	
	# [Check 3] 黑名单检查
	if clean_file_name.to_lower() in RESTRICTED_FILES:
		return {
			"success": false, 
			"data": "Security Error: Creation of '%s.md' is restricted. Use 'todo_list' or 'access_project_memory' tools." % clean_file_name
		}
	
	folder_path = _ensure_trailing_slash(folder_path)
	var full_path: String = folder_path + clean_file_name + "." + file_format
	
	# [Check 4] 路径安全检查
	var safety_check: String = validate_path_safety(full_path)
	if not safety_check.is_empty():
		return {"success": false, "data": safety_check}
	
	return _create_file(full_path, folder_path, content)


# --- Private Functions ---

func _ensure_trailing_slash(p_path: String) -> String:
	if not p_path.ends_with("/"):
		return p_path + "/"
	return p_path


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
	
	return {"success": true, "data": "Markdown file created successfully: " + p_full_path}
