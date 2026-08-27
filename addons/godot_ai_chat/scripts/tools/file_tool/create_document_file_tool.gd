@tool
extends AiTool

## Markdown 文档创建工具。
##
## 用于创建 .md 文档文件。markdown 属于纯文档内容，不涉及项目代码/结构，
## 因此不受 PATH_BLACKLIST 路径管控（/.git/、/.godot/、/addons/ 等）限制，
## 允许在任意 res:// 路径下写入文档。
## 注意：目标文件夹必须已存在，不会自动创建。


# --- Constants ---

## 固定文件扩展名
const VALID_EXTENSION: String = "md"


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_document_file"
	tool_description = "Creates a markdown document file."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_name": {
				"type": "string",
				"description": "File name WITHOUT the `.md` extension."
			},
			"path": {
				"type": "string",
				"description": "Target folder path where the document will be saved. The folder must already exist."
			},
			"content": {
				"type": "string",
				"description": "The Markdown content to write into the file."
			}
		},
		"required": ["file_name", "path", "content"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var file_name: String = p_args.get("file_name", "").strip_edges()
	var folder_path: String = p_args.get("path", "")
	var content: String = p_args.get("content", "")
	
	if file_name.is_empty():
		return ToolResult.fail("Error: 'file_name' is required.")
	if folder_path.is_empty():
		return ToolResult.fail("Error: 'path' is required.")
	if content.is_empty():
		return ToolResult.fail("Error: 'content' is required.")
	
	# 规范化路径：统一正斜杠、确保以 / 结尾
	folder_path = folder_path.replace("\\", "/")
	if not folder_path.ends_with("/"):
		folder_path += "/"
	
	# 自动追加 .md 后缀（若 AI 已传入带后缀名称则避免重复）
	if not file_name.ends_with("." + VALID_EXTENSION):
		file_name += "." + VALID_EXTENSION
	
	var full_path: String = folder_path + file_name
	
	# 基本合法性校验（仅豁免路径黑名单管控，仍防止越界路径）
	if not full_path.begins_with("res://"):
		return ToolResult.fail("Error: Path must start with 'res://'.")
	if full_path.contains(".."):
		return ToolResult.fail("Error: Path traversal ('..') is not allowed.")
	
	# 同名文件防覆盖检查 → 失败并提示
	if FileAccess.file_exists(full_path):
		return ToolResult.fail("Error: A file with the same name already exists at %s. Use a different file name or path." % full_path)
	
	# 目标文件夹必须已存在
	if not DirAccess.dir_exists_absolute(folder_path):
		return ToolResult.fail("Error: Target folder '%s' does not exist. Use `create_folder` to create it first." % folder_path)
	
	var file := FileAccess.open(full_path, FileAccess.WRITE)
	if not file:
		return ToolResult.fail("Error: Failed to create file: " + str(FileAccess.get_open_error()))
	
	file.store_string(content)
	file.close()
	
	ToolBox.update_editor_filesystem(full_path)
	return ToolResult.ok("Markdown file created: %s" % full_path)
