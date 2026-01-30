@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "get_script_slices"
	tool_description = "Open a script in the editor and return its content sliced by logic blocks."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_path": { "type": "string", "description": "Full path to the script file." }
		},
		"required": ["file_path"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var path: String = p_args.get("file_path", "")
	
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "File not found: %s" % path}
	
	var code_edit := _get_code_edit(path)
	if not code_edit:
		return {"success": false, "data": "Failed to open script editor."}
	
	_focus_script_editor()
	var view := get_sliced_code_view(code_edit)
	
	return {"success": true, "data": view}
