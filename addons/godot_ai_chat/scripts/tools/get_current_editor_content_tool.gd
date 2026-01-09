@tool
extends AiTool


func _init() -> void:
	tool_name = "get_current_editor_content"
	tool_description = "Get the file path of the currently active editor tab. Returns the path of the active script OR scene. Does NOT return file content."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(_args: Dictionary, _context_provider: Object) -> Dictionary:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	
	# 1. 优先判断脚本编辑器是否在前台
	if script_editor and script_editor.is_visible_in_tree():
		var current_script: Script = script_editor.get_current_script()
		
		if current_script:
			return {
				"success": true, 
				"data": {
					"type": "script",
					"path": current_script.resource_path
				}
			}
		else:
			return {"success": false, "data": "Script editor is active but no script is open."}
	
	# 2. 如果脚本编辑器不在前台，则认为在编辑场景 (2D/3D)
	var edited_root = EditorInterface.get_edited_scene_root()
	if edited_root:
		var path = edited_root.scene_file_path
		# 处理新建且从未保存过的场景
		if path.is_empty():
			path = "[Unsaved New Scene]"
		
		return {
			"success": true, 
			"data": {
				"type": "scene",
				"path": path
			}
		}
	
	return {"success": false, "data": "No active Scene found in Editor Tab."}
