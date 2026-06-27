@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "run_scene"
	tool_description = "Runs a specified scene file in the editor, starting gameplay from that scene."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"scene_path": {
				"type": "string",
				"description": "The full path to the .tscn or .scn scene file to run (e.g., 'res://scenes/main.tscn')."
			}
		},
		"required": ["scene_path"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var scene_path: String = p_args.get("scene_path", "")
	
	# 1. 参数校验
	if scene_path.is_empty():
		return {"success": false, "data": "Error: 'scene_path' is required."}
	
	# 2. 安全检查（路径黑名单）
	var safety_err: String = validate_path_safety(scene_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	# 3. 扩展名校验 — 支持 .tscn 和 .scn
	var ext: String = scene_path.get_extension().to_lower()
	var allowed_exts: Array[String] = ["tscn", "scn"]
	if ext not in allowed_exts:
		return {"success": false, "data": "Error: Invalid file extension '%s'. Allowed extensions: %s" % [ext, ", ".join(allowed_exts)]}
	
	# 4. 文件存在性检查
	if not FileAccess.file_exists(scene_path):
		return {"success": false, "data": "Error: Scene file not found: %s" % scene_path}
	
	# 5. 检查是否在编辑器中
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Error: This tool can only be used in the Godot editor."}
	
	# 6. 执行运行场景
	EditorInterface.play_custom_scene(scene_path)
	return {"success": true, "data": "✅ Running scene: %s" % scene_path}
