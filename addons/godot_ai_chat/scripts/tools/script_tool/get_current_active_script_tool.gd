@tool
extends AiTool

func _init() -> void:
	tool_name = "get_current_active_script"
	tool_description = "Get the file name and source code of the currently active script in Script Editor."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	
	if not script_editor:
		return {"success": false, "data": "Script Editor not found."}
	
	var current_script: Script = script_editor.get_current_script()
	
	if current_script:
		var file_path = current_script.resource_path
		var source_code = current_script.source_code
		
		# 尝试获取编辑器中未保存的最新文本
		var current_editor = script_editor.get_current_editor()
		if current_editor:
			var base_editor = current_editor.get_base_editor()
			if base_editor and "text" in base_editor:
				source_code = base_editor.text
		
		# 构造 Markdown 格式的返回字符串
		var file_name = file_path.get_file()
		var extension = file_name.get_extension()
		
		# 根据后缀名确定 Markdown 代码块语言
		var lang = "gdscript"
		if extension == "gdshader":
			lang = "glsl"
			
		var markdown_content = "### File: %s\n\n```%s\n%s\n```" % [file_name, lang, source_code]
		
		return {
			"success": true, 
			"data": markdown_content
		}
	
	return {"success": false, "data": "No active script found in Script Editor."}
