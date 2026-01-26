@tool
extends BaseScriptTool

## 创建新的空脚本文件。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_new_script"
	tool_description = "Creates a new empty script. NEXT STEP: Use 'fill_empty_script' to add content."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path where the script should be created."
			}
		},
		"required": ["path"]
	}


## 执行创建脚本操作
## [param p_args]: 包含 path 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var new_script_path: String = p_args.get("path", "")
	
	var validation_result: Dictionary = _validate_script_path(new_script_path)
	if not validation_result.get("success", false):
		return validation_result
	
	if FileAccess.file_exists(new_script_path):
		return {"success": false, "data": "Error: File '%s' already exists. this tool cannot overwrite existing files." % new_script_path}
	
	var dir_check_result: Dictionary = _check_directory_exists(new_script_path)
	if not dir_check_result.get("success", false):
		return dir_check_result
	
	return _create_empty_script(new_script_path)


# --- Private Functions ---

## 验证脚本路径和文件扩展名
## [param p_path]: 脚本路径
## [return]: 验证结果字典
func _validate_script_path(p_path: String) -> Dictionary:
	var security_error: String = validate_path_safety(p_path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	var ext_error: String = validate_file_extension(p_path)
	if not ext_error.is_empty():
		return {"success": false, "data": ext_error}
	
	if ".." in p_path:
		return {"success": false, "data": "Error: Path traversal ('..') is not allowed."}
	
	return {"success": true}


## 检查目录是否存在
## [param p_path]: 脚本路径
## [return]: 检查结果字典
func _check_directory_exists(p_path: String) -> Dictionary:
	var base_dir: String = p_path.get_base_dir()
	var dir_access: DirAccess = DirAccess.open("res://")
	
	if not dir_access.dir_exists(base_dir):
		return {"success": false, "data": "Directory not found: %s. Please use 'create_folder' tool first." % base_dir}
	
	return {"success": true}


## 创建空脚本文件
## [param p_path]: 脚本路径
## [return]: 操作结果字典
func _create_empty_script(p_path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(p_path, FileAccess.WRITE)
	if file == null:
		return {"success": false, "data": "Error: Failed to open file: " + str(FileAccess.get_open_error())}
	
	file.store_string("")
	file.close()
	
	ToolBox.update_editor_filesystem(p_path)
	
	return {"success": true, "data": "Empty file created successfully at: " + p_path}
