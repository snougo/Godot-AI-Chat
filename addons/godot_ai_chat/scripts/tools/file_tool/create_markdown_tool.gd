@tool
extends AiTool

## Markdown 文档创建工具。
## 用于创建 .md Markdown 文档文件。
## 注意：目标文件夹必须已存在，不会自动创建。


# --- Enums / Constants ---

const VALID_EXTENSIONS: Array[String] = ["md"]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_markdown"
	tool_description = "Creates a `.md` markdown document file."


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
				"description": "File name with .md extension (e.g., 'xxx.md')."
			},
			"content": {
				"type": "string",
				"description": "Initial markdown content."
			}
		},
		"required": ["path", "file_name", "content"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var folder_path: String = p_args.get("path", "")
	var file_name: String = p_args.get("file_name", "")
	
	if folder_path.is_empty() or file_name.is_empty():
		return {"success": false, "data": "Error: 'path' and 'file_name' are required."}
	
	if not folder_path.ends_with("/"):
		folder_path += "/"
	
	var full_path: String = folder_path + file_name
	
	var safety_err: String = validate_path_safety(full_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	if FileAccess.file_exists(full_path):
		return {"success": false, "data": "Error: File already exists at %s. Overwriting is not allowed." % full_path}
	
	if not DirAccess.dir_exists_absolute(folder_path):
		return {"success": false, "data": "Error: Target folder '%s' does not exist. Use `manage_folder` to create it first." % folder_path}
	
	var ext: String = full_path.get_extension().to_lower()
	if ext not in VALID_EXTENSIONS:
		return {"success": false, "data": "Error: Invalid extension '.%s'. Markdown files must use: .md." % ext}
	
	var content: String = p_args.get("content", "")
	if content.is_empty():
		return {"success": false, "data": "Error: 'content' is required."}
	
	var file := FileAccess.open(full_path, FileAccess.WRITE)
	if not file:
		return {"success": false, "data": "Failed to create file: " + str(FileAccess.get_open_error())}
	
	file.store_string(content)
	file.close()
	
	# Markdown 文件需要刷新整个文件系统以更新文件系统对话框
	ToolBox.refresh_editor_filesystem()
	
	return {"success": true, "data": "Markdown file created: %s" % full_path}
