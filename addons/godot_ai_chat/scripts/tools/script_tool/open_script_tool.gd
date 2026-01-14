@tool
extends AiTool

const ALLOWED_EXTENSIONS: Array[String] = ["gd", "gdshader"]


func _init() -> void:
	tool_name = "open_script"
	tool_description = "Opens a script file in the Godot Script Editor."


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


func execute(args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path = args.get("path", "")
	
	# 1. 基础路径安全检查 (调用基类)
	var safety_error = validate_path_safety(path)
	if not safety_error.is_empty():
		return {"success": false, "data": safety_error}
	
	# 2. 扩展名白名单检查
	var ext = path.get_extension().to_lower()
	if not ext in ALLOWED_EXTENSIONS:
		return {"success": false, "data": "Security Error: File extension '%s' is not allowed. Allowed: %s" % [ext, str(ALLOWED_EXTENSIONS)]}
	
	# 3. 文件存在性检查
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "File not found: %s" % path}
	
	# 4. 加载并验证资源类型
	var res = load(path)
	if not res:
		return {"success": false, "data": "Failed to load resource: %s" % path}
	
	if not (res is Script):
		return {"success": false, "data": "Resource is not a Script: %s" % path}
	
	# 5. 执行打开操作
	EditorInterface.edit_resource(res)
	return {"success": true, "data": "Opened script: %s" % path}
