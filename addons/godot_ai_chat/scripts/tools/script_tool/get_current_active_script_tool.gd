@tool
extends BaseScriptTool

## 读取活动脚本内容。
## 首先执行以获取编辑工具所需的 'slice_index'。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "get_current_active_script"
	tool_description = "Reads current active script content."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


## 执行获取当前活动脚本操作
## [param p_args]: 参数字典（此工具不需要参数）
## [return]: 包含脚本内容的字典
func execute(p_args: Dictionary) -> Dictionary:
	var script_editor: ScriptEditor = EditorInterface.get_script_editor()
	
	if not script_editor:
		return {"success": false, "data": "Script Editor not found."}
	
	var current_script: Script = script_editor.get_current_script()
	
	if not current_script:
		return {"success": false, "data": "No active script found in Script Editor."}
	
	var file_path: String = current_script.resource_path
	var source_code: String = _get_source_code(current_script, script_editor)
	
	var slices: Array = parse_script_to_slices(source_code)
	
	return _build_markdown_response(file_path, source_code, slices)

# --- Private Functions ---

## 获取源代码
## [param p_script]: 脚本资源
## [param p_script_editor]: 脚本编辑器
## [return]: 源代码字符串
func _get_source_code(p_script: Script, p_script_editor: ScriptEditor) -> String:
	var source_code: String = p_script.source_code
	
	var current_editor = p_script_editor.get_current_editor()
	if current_editor:
		var base_editor = current_editor.get_base_editor()
		if base_editor and "text" in base_editor:
			source_code = base_editor.text
	
	return source_code


## 构建 Markdown 响应
## [param p_file_path]: 文件路径
## [param p_source_code]: 源代码
## [param p_slices]: 切片数组
## [return]: 包含成功状态和 Markdown 内容的字典
func _build_markdown_response(p_file_path: String, p_source_code: String, p_slices: Array) -> Dictionary:
	var file_name: String = p_file_path.get_file()
	var extension: String = p_file_path.get_extension()
	var lang: String = "gdscript"
	if extension == "gdshader":
		lang = "glsl"
	
	var lines: PackedStringArray = p_source_code.split("\n")
	
	var markdown_content: String = "### File: %s\n" % file_name
	markdown_content += "**Path:** `%s`\n" % p_file_path
	markdown_content += "**Total Lines:** %d\n" % lines.size()
	markdown_content += "**Total Slices:** %d\n\n" % p_slices.size()
	markdown_content += "---\n\n"
	
	for i in range(p_slices.size()):
		var slice: Dictionary = p_slices[i]
		var start: int = slice.start_line
		var end: int = slice.end_line
		
		markdown_content += "#### Slice %d (Lines %d-%d)\n" % [i, start + 1, end + 1]
		markdown_content += "```%s\n" % lang
		
		for line_idx in range(start, end + 1):
			if line_idx < lines.size():
				var line_num_str: String = str(line_idx + 1).pad_zeros(3)
				markdown_content += "%s | %s\n" % [line_num_str, lines[line_idx]]
				
		markdown_content += "```\n\n"
	
	return {"success": true, "data": markdown_content}
