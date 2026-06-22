@tool
extends AiTool

## 保存编辑中的场景或脚本文件到磁盘。
## 服务于 Scene Builder 和 Script Editor 技能。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "save_edited_file"
	tool_description = "Saves the currently edited file (scene or script) to disk."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_type": {
				"type": "string",
				"enum": ["scene", "script"],
				"description": "Type of file to save: 'scene' for the currently open scene, 'script' for the currently open script."
			}
		},
		"required": ["file_type"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Editor only tool."}
	
	var file_type: String = p_args.get("file_type", "")
	
	match file_type:
		"scene":
			return _save_scene()
		"script":
			return _save_script()
		_:
			return {"success": false, "data": "Invalid file_type '%s'. Must be 'scene' or 'script'." % file_type}


# --- Private Functions ---

func _save_scene() -> Dictionary:
	var root: Node = EditorInterface.get_edited_scene_root()
	if not root:
		return {"success": false, "data": "No active scene to save."}
	
	var path: String = root.scene_file_path
	if path.is_empty():
		return {"success": false, "data": "Scene has never been saved. Save it manually in the editor first, or use 'create_scene' tool."}
	
	var err: Error = EditorInterface.save_scene()
	if err == OK:
		return {"success": true, "data": "Scene saved: %s" % path}
	
	return {"success": false, "data": "Failed to save scene. Error: %d" % err}


func _save_script() -> Dictionary:
	var se: ScriptEditor = EditorInterface.get_script_editor()
	var current_script: Script = se.get_current_script()
	if not current_script:
		return {"success": false, "data": "No active script to save."}
	
	var path: String = current_script.resource_path
	if path.is_empty():
		return {"success": false, "data": "Script has never been saved. Use 'create_script' first."}
	
	# ScriptEditor 原生保存 — 自动处理 CodeEdit→Script 同步并清除 dirty flag
	se.save_all_scripts()
	
	return {"success": true, "data": "Script saved: %s" % path}
