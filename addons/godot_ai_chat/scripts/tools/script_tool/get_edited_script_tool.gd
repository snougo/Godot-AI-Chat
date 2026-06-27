@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "get_edited_script"
	tool_description = "Gets the content of the currently open script in the Script Editor with line numbers. Returns error if no script is currently open."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {}
	}


func execute(_p_args: Dictionary) -> Dictionary:
	# 获取当前已打开的脚本
	var current_script := EditorInterface.get_script_editor().get_current_script()
	if not current_script:
		return {"success": false, "data": "No script is currently open in the Script Editor."}
	
	var current_path := current_script.resource_path
	
	# [Security Check] Validate path against blacklist (inherited from AiTool)
	var safety_err: String = validate_path_safety(current_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	# 获取 CodeEdit 实例（不打开新脚本）
	var code_edit := _get_current_code_edit()
	if not code_edit:
		return {"success": false, "data": "Failed to access the script editor."}
	
	_focus_script_editor()
	
	# 返回带行号的完整脚本内容
	var view: String = get_full_script_with_line_numbers(code_edit)
	
	return {"success": true, "data": "File: %s\n\n%s" % [current_path, view]}
