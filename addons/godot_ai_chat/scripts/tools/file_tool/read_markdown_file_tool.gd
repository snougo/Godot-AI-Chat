@tool
extends AiTool

## Markdown 文件读取工具。
## 只能读取 Markdown(.md) 文件，用于技能 Sub-Agent。
## 不依赖第三方 ContextProvider，直接通过 FileAccess 读取。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "read_markdown_file"
	tool_description = "Reads the content of a Markdown (.md) file."
	security_level = SecurityLevel.READ_ONLY


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the .md file."
			}
		},
		"required": ["path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var path: String = p_args.get("path", "")
	
	if path.is_empty():
		return ToolResult.fail("Error: 'path' is required.")
	
	# 路径安全校验
	if not path.begins_with("res://"):
		return ToolResult.fail("Error: Path must start with 'res://'.")
	if ".." in path:
		return ToolResult.fail("Error: Path traversal ('..') is not allowed.")
	
	# 强制校验扩展名：只允许 .md
	var ext: String = path.get_extension().to_lower()
	if ext != "md":
		return ToolResult.fail("Error: Invalid extension '.%s'. This tool can only read '.md' files." % ext)
	
	if not FileAccess.file_exists(path):
		return ToolResult.fail("Error: File not found: %s" % path)
	
	var content: String = FileAccess.get_file_as_string(path)
	return ToolResult.ok("Content for File: `%s`\n\n%s" % [path.get_file(), content])
