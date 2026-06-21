@tool
extends AiTool

## 文本文件创建工具。
## 支持创建多种纯文本格式文件：着色器(.gdshader)、Markdown(.md)、
## 纯文本(.txt)、JSON(.json) 等。
## 注意：目标文件夹必须已存在，不会自动创建。


# --- Enums / Constants ---

## 文件类型配置映射表
## key: file_type 值, value: { extensions, restricted_names (可选) }
const FILE_TYPE_CONFIG: Dictionary = {
	"shader":   {"extensions": ["gdshader"]},
	"markdown": {"extensions": ["md"], "restricted_names": ["todo", "memory"]},
	"text":     {"extensions": ["txt"]},
	"json":     {"extensions": ["json"]}
}


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_text_file"
	tool_description = "Creates a new text-based file (shader, markdown, text, json, etc)."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	var file_types: Array[String] = []
	for key in FILE_TYPE_CONFIG:
		file_types.append(key)
	file_types.sort()
	
	return {
		"type": "object",
		"properties": {
			"file_type": {
				"type": "string",
				"enum": file_types,
				"description": "The type of file to create: " + ", ".join(file_types) + "."
			},
			"path": {
				"type": "string",
				"description": "Target folder path (e.g., 'res://xxx/'). The folder must already exist."
			},
			"file_name": {
				"type": "string",
				"description": "File name with extension (e.g., 'my_file.gdshader', 'doc.md')."
			},
			"content": {
				"type": "string",
				"description": "Initial file content."
			}
		},
		"required": ["file_type", "path", "file_name", "content"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var file_type: String = p_args.get("file_type", "")
	var folder_path: String = p_args.get("path", "")
	var file_name: String = p_args.get("file_name", "")
	
	if file_type.is_empty() or folder_path.is_empty() or file_name.is_empty():
		return {"success": false, "data": "Error: 'file_type', 'path', and 'file_name' are required."}
	
	# 确保文件夹路径以 / 结尾
	if not folder_path.ends_with("/"):
		folder_path += "/"
	
	var full_path: String = folder_path + file_name
	
	# 安全校验
	var safety_err: String = validate_path_safety(full_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	if FileAccess.file_exists(full_path):
		return {"success": false, "data": "Error: File already exists at %s. Overwriting is not allowed." % full_path}
	
	# 检查目标文件夹是否存在（禁止越权创建文件夹）
	if not DirAccess.dir_exists_absolute(folder_path):
		return {"success": false, "data": "Error: Target folder '%s' does not exist. Use `manage_folder` to create it first." % folder_path}
	
	# 查表校验 file_type
	if not FILE_TYPE_CONFIG.has(file_type):
		var valid_types: String = ", ".join(FILE_TYPE_CONFIG.keys())
		return {"success": false, "data": "Error: Unknown file_type '%s'. Valid: %s." % [file_type, valid_types]}
	
	var config: Dictionary = FILE_TYPE_CONFIG[file_type]
	var valid_extensions: Array[String] = config["extensions"]
	
	# 校验扩展名
	var ext: String = full_path.get_extension().to_lower()
	if ext not in valid_extensions:
		var allowed: String = ", ".join(valid_extensions)
		return {"success": false, "data": "Error: Invalid extension '.%s'. '%s' files must use: %s." % [ext, file_type, allowed]}
	
	# 文件名黑名单检查（仅适用于有 restricted_names 的类型）
	if config.has("restricted_names"):
		var basename: String = full_path.get_file().get_basename().to_lower()
		var restricted: Array[String] = config["restricted_names"]
		if basename in restricted:
			return {
				"success": false,
				"data": "Security Error: Creation of '%s.%s' is restricted." % [basename, ext]
			}
	
	# 内容校验
	var content: String = p_args.get("content", "")
	if content.is_empty():
		return {"success": false, "data": "Error: 'content' is required for file_type '%s'." % file_type}
	
	# 写入文件
	var file := FileAccess.open(full_path, FileAccess.WRITE)
	if not file:
		return {"success": false, "data": "Failed to create file: " + str(FileAccess.get_open_error())}
	
	file.store_string(content)
	file.close()
	
	# 不同类型的文件系统刷新策略
	if file_type == "markdown":
		ToolBox.refresh_editor_filesystem()
	else:
		ToolBox.update_editor_filesystem(full_path)
	
	return {"success": true, "data": "%s file created: %s" % [file_type.capitalize(), full_path]}
