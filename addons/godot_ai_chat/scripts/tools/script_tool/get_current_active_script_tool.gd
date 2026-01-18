@tool
extends BaseScriptTool

func _init() -> void:
	tool_name = "get_current_active_script"
	tool_description = "Reads active script content. EXECUTE FIRST to get 'slice_index' for editing tools."

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
	
	if not current_script:
		return {"success": false, "data": "No active script found in Script Editor."}
	
	var file_path = current_script.resource_path
	var source_code = current_script.source_code
	
	# 尝试获取编辑器中未保存的最新文本
	var current_editor = script_editor.get_current_editor()
	if current_editor:
		var base_editor = current_editor.get_base_editor()
		if base_editor and "text" in base_editor:
			source_code = base_editor.text
	
	# 构造 Markdown
	var file_name = file_path.get_file()
	var extension = file_name.get_extension()
	var lang = "gdscript"
	if extension == "gdshader":
		lang = "glsl"
	
	# --- 调用基类统一解析逻辑 ---
	var slices = _parse_script_to_slices(source_code)
	# --------------------------
	
	var lines = source_code.split("\n")
	
	var markdown_content = "### File: %s\n" % file_name
	markdown_content += "**Path:** `%s`\n" % file_path
	markdown_content += "**Total Lines:** %d\n" % lines.size()
	markdown_content += "**Total Slices:** %d\n\n" % slices.size()
	markdown_content += "---\n\n"
	
	for i in range(slices.size()):
		var slice = slices[i]
		var start = slice.start_line
		var end = slice.end_line
		
		markdown_content += "#### Slice %d (Lines %d-%d)\n" % [i, start + 1, end + 1]
		markdown_content += "```%s\n" % lang
		
		for line_idx in range(start, end + 1):
			if line_idx < lines.size():
				var line_num_str = str(line_idx + 1).pad_zeros(3)
				markdown_content += "%s | %s\n" % [line_num_str, lines[line_idx]]
				
		markdown_content += "```\n\n"
		
	return {
		"success": true, 
		"data": markdown_content
	}
