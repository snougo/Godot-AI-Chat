@tool
extends BaseSceneTool

func _init():
	tool_name = "open_scene"
	tool_description = "Opens a scene file in Godot Editor. EXECUTE BEFORE manipulating nodes."

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the scene file (e.g., res://path/main.tscn)."
			}
		},
		"required": ["path"]
	}

func execute(args: Dictionary) -> Dictionary:
	if not args.has("path"):
		return {"success": false, "data": "Missing 'path' argument."}
	
	var path: String = args["path"]
	
	# 1. 路径安全检查 (复用 AiTool 基类逻辑)
	var security_error = validate_path_safety(path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	# 2. 文件存在性检查
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "File not found: " + path}
		
	# 3. 文件类型检查
	if not (path.ends_with(".tscn") or path.ends_with(".scn") or path.ends_with(".escn")):
		return {"success": false, "data": "File is not a scene file (.tscn, .scn, .escn): " + path}
	
	# 执行打开操作
	EditorInterface.open_scene_from_path(path)
	return {"success": true, "data": "Opened scene: " + path}
