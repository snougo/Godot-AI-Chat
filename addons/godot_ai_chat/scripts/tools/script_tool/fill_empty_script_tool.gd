@tool
extends BaseScriptTool

## 向新的空脚本文件写入代码。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "fill_empty_script"
	tool_description = "Only support writing code to a NEW EMPTY file. Using 'insert_script_code' for existing files."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the new empty script."
			},
			"code_content": {
				"type": "string",
				"description": "The GDScript code to write."
			}
		},
		"required": ["path", "code_content"]
	}


## 执行填充脚本操作
## [param p_args]: 包含 path 和 code_content 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var path: String = p_args.get("path", "")
	var content: String = p_args.get("code_content", "")
	
	var validation_result: Dictionary = _validate_script_path(path)
	if not validation_result.get("success", false):
		return validation_result
	
	var editor_result: Dictionary = _get_script_editor(path)
	if not editor_result.get("success", false):
		return editor_result
	
	var base_editor: Control = editor_result.base_editor
	
	var empty_check: Dictionary = _check_script_is_empty(base_editor)
	if not empty_check.get("success", false):
		return empty_check
	
	base_editor.text = content
	
	return {"success": true, "data": "Successfully populated '" + path + "'. The file is now in an unsaved state (*)."}


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
	
	return {"success": true}


## 获取脚本编辑器
## [param p_path]: 脚本路径
## [return]: 包含 base_editor 的字典
func _get_script_editor(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path + ". Please use 'create_script' tool first."}
	
	var res: Resource = load(p_path)
	if not res is Script:
		return {"success": false, "data": "Error: Resource at path is not a script."}
	
	var script: Script = res as Script
	EditorInterface.edit_resource(script)
	
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	var current_editor: ScriptEditorBase = script_editor.get_current_editor()
	
	if not current_editor:
		return {"success": false, "data": "Error: Could not access script editor."}
	
	var base_editor: Control = current_editor.get_base_editor()
	if not base_editor:
		return {"success": false, "data": "Error: Could not access text editor control."}
	
	return {"success": true, "base_editor": base_editor}


## 检查脚本是否为空
## [param p_base_editor]: 基础编辑器控件
## [return]: 检查结果字典
func _check_script_is_empty(p_base_editor: Control) -> Dictionary:
	if p_base_editor.text.strip_edges().length() > 0:
		return {"success": false, "data": "Error: Script is not empty; operation not allowed."}
	return {"success": true}
