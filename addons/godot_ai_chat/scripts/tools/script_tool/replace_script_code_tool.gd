@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "replace_script_code"
	tool_description = "Replaces a specific block of code by searching for the exact text content. The old code is commented out, and new code is inserted above it."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the script file (res://...)."
			},
			"target_code": {
				"type": "string",
				"description": "The EXACT code block currently in the file that needs to be replaced. Must include correct indentation and formatting."
			},
			"new_code": {
				"type": "string",
				"description": "The new GDScript code to insert."
			}
		},
		"required": ["path", "target_code", "new_code"]
	}


func execute(args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var path = args.get("path", "")
	var target_code: String = args.get("target_code", "")
	var new_code: String = args.get("new_code", "")
	
	# 1. 路径安全检查
	var security_error = validate_path_safety(path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	# 2. 扩展名检查
	var ext_error = validate_file_extension(path)
	if not ext_error.is_empty():
		return {"success": false, "data": ext_error}
	
	if target_code.is_empty():
		return {"success": false, "data": "Error: 'target_code' cannot be empty."}
	
	# 3. 确保脚本存在
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "File not found: " + path}
		
	var res = load(path)
	if not res is Script:
		return {"success": false, "data": "Resource is not a script."}
	
	# 4. 打开编辑器
	EditorInterface.edit_resource(res)
	var script_editor = EditorInterface.get_script_editor()
	var current_editor = script_editor.get_current_editor()
	if not current_editor:
		return {"success": false, "data": "Could not access script editor."}
		
	var base_editor = current_editor.get_base_editor()
	if not base_editor:
		return {"success": false, "data": "Could not access code editor control."}
	
	# 5. 搜索定位
	var full_text: String = base_editor.text
	var match_index = full_text.find(target_code)
	
	if match_index == -1:
		var target_code_fixed = target_code.replace("\r\n", "\n")
		var full_text_fixed = full_text.replace("\r\n", "\n")
		match_index = full_text_fixed.find(target_code_fixed)
	
	if match_index == -1:
		return {"success": false, "data": "Error: Could not find the exact 'target_code' in the file."}
	
	# 6. 计算范围 (修复部分)
	# 通过统计匹配位置之前的换行符数量来确定行号
	var text_before = full_text.substr(0, match_index)
	var start_line = text_before.count("\n")
	
	var line_count = target_code.count("\n")
	var end_line = start_line + line_count
	
	# 7. 执行修改
	if base_editor.has_method("begin_complex_operation"):
		base_editor.begin_complex_operation()
	
	for i in range(start_line, end_line + 1):
		if i < base_editor.get_line_count():
			var line_text = base_editor.get_line(i)
			if not line_text.strip_edges().is_empty() and not line_text.strip_edges().begins_with("#"):
				base_editor.set_line(i, "# " + line_text)
	
	if not new_code.ends_with("\n"):
		new_code += "\n"
	
	base_editor.insert_text(new_code, start_line, 0)
	
	if base_editor.has_method("end_complex_operation"):
		base_editor.end_complex_operation()
		
	return {"success": true, "data": "Successfully replaced code block starting at line %d." % (start_line + 1)}
