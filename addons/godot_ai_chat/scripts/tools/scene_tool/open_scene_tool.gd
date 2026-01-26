@tool
extends BaseSceneTool

## 在 Godot 编辑器中打开场景文件。
## 在操作节点之前执行。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "open_scene"
	tool_description = "Opens a `.tscn` file in Godot Editor. EXECUTE BEFORE `get_current_active_scene`."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the `.tscn` file (e.g., res://xxxx/xxxx.tscn)."
			}
		},
		"required": ["path"]
	}


## 执行打开场景操作
## [param p_args]: 包含 path 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	if not p_args.has("path"):
		return {"success": false, "data": "Missing 'path' argument."}
	
	var path: String = p_args["path"]
	
	var validation_result: Dictionary = _validate_scene_path(path)
	if not validation_result.get("success", false):
		return validation_result
	
	EditorInterface.open_scene_from_path(path)
	return {"success": true, "data": "Opened scene: " + path}


# --- Private Functions ---

## 验证场景路径
## [param p_path]: 场景路径
## [return]: 验证结果字典
func _validate_scene_path(p_path: String) -> Dictionary:
	var security_error: String = validate_path_safety(p_path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "File not found: " + p_path}
	
	if not _is_valid_scene_file(p_path):
		return {"success": false, "data": "File is not a scene file (.tscn, .scn, .escn): " + p_path}
	
	return {"success": true}


## 检查是否为有效的场景文件
## [param p_path]: 文件路径
## [return]: 是否为有效场景文件
func _is_valid_scene_file(p_path: String) -> bool:
	return p_path.ends_with(".tscn")
