@tool
extends BaseScriptTool

## 在 Godot 脚本编辑器中打开脚本文件。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "open_script"
	tool_description = "Opens a script file in the Godot Script Editor. EXECUTE BEFORE `get_current_active_script`."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the script file."
			}
		},
		"required": ["path"]
	}


## 执行打开脚本操作
## [param p_args]: 包含 path 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var path: String = p_args.get("path", "")
	
	var validation_result: Dictionary = _validate_script_path(path)
	if not validation_result.get("success", false):
		return validation_result
	
	var resource_result: Dictionary = _load_and_validate_script(path)
	if not resource_result.get("success", false):
		return resource_result
	
	EditorInterface.edit_resource(resource_result.script)
	
	return {"success": true, "data": "Opened script: %s" % path}


# --- Private Functions ---

## 验证脚本路径
## [param p_path]: 脚本路径
## [return]: 验证结果字典
func _validate_script_path(p_path: String) -> Dictionary:
	var safety_error: String = validate_path_safety(p_path)
	if not safety_error.is_empty():
		return {"success": false, "data": safety_error}
	
	var ext_error: String = validate_file_extension(p_path)
	if not ext_error.is_empty():
		return {"success": false, "data": ext_error}
	
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "File not found: %s" % p_path}
	
	return {"success": true}


## 加载并验证脚本资源
## [param p_path]: 脚本路径
## [return]: 包含 script 的字典
func _load_and_validate_script(p_path: String) -> Dictionary:
	var res = load(p_path)
	if not res:
		return {"success": false, "data": "Failed to load resource: %s" % p_path}
	
	if not (res is Script):
		return {"success": false, "data": "Resource is not a Script: %s" % p_path}
	
	return {"success": true, "script": res}
