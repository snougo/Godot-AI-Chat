@tool
extends AiTool


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
	
	# 构造 Markdown 格式的返回字符串
	var file_name = file_path.get_file()
	var extension = file_name.get_extension()
	var lang = "gdscript"
	if extension == "gdshader":
		lang = "glsl"
	
	# 解析切片
	var slices = _parse_script_to_slices(source_code)
	# Godot 4 split 行为: "a\nb".split("\n") -> ["a", "b"]
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
				# 格式： 行号 | 代码
				# 行号补齐为3位
				var line_num_str = str(line_idx + 1).pad_zeros(3)
				markdown_content += "%s | %s\n" % [line_num_str, lines[line_idx]]
				
		markdown_content += "```\n\n"
		
	return {
		"success": true, 
		"data": markdown_content
	}


# --- 辅助逻辑 ---

func _parse_script_to_slices(code: String) -> Array:
	var lines = code.split("\n")
	var slices = []
	var current_start = 0
	
	# 使用 Regex 匹配函数定义
	var func_regex = RegEx.new()
	func_regex.compile("^\\s*(static\\s+)?func\\s+")
	
	for i in range(lines.size()):
		var line = lines[i]
		
		if func_regex.search(line):
			# 找到 func 行，尝试向上回溯以包含相关注释
			var split_idx = i
			var k = i - 1
			
			# 向上查找连续的注释行
			while k >= current_start:
				var prev_line = lines[k].strip_edges()
				if prev_line.begins_with("#"):
					split_idx = k # 将切分点上移至注释行
					k -= 1
				else:
					# 遇到非注释行（空行或代码），停止回溯
					break
			
			# 只有当切分点大于 current_start 时才切分
			# 避免文件开头的 func 导致切出空片
			if split_idx > current_start:
				slices.append({"start_line": current_start, "end_line": split_idx - 1})
				current_start = split_idx
	
	# 添加最后一个块
	if current_start < lines.size():
		slices.append({"start_line": current_start, "end_line": lines.size() - 1})
	elif lines.size() == 0:
		# 处理空文件情况
		slices.append({"start_line": 0, "end_line": 0})
	
	return slices
