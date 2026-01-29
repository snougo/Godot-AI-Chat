@tool
extends BaseScriptTool

## 代码编辑工具
##
## 负责脚本内容的增删改查。直接对当前活跃的脚本编辑器进行操作。
## 请先使用 script_manager (open/switch) 切换到目标文件。

# --- Init ---

func _init() -> void:
	tool_name = "code_editor"
	tool_description = "Edit current active script content in Godot Script Editor."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["rewrite", "insert", "delete", "add_empty_line"],
				"description": "The editing action."
			},
			"content": {
				"type": "string",
				"description": "Code content. Required for rewrite/insert/delete. Ignored for add_empty_line."
			},
			"line": {
				"type": "integer",
				"description": "Start line (1-based). Required for insert and add_empty_line."
			},
			"file_name": {
				"type": "string",
				"description": "The target script file name (e.g., 'my_script.gd'). Required to verify against the currently active script."
			}
		},
		"required": ["action", "file_name"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")
	var content: String = p_args.get("content", "")
	var line_arg: int = p_args.get("line", 0)
	
	# 1. 预处理文件名参数：只取文件名部分，忽略路径
	var raw_file_name: String = p_args.get("file_name", "")
	var expected_file_name: String = raw_file_name.get_file()
	
	if expected_file_name.is_empty():
		return {"success": false, "data": "Missing required parameter: 'file_name'."}
	
	# 获取当前活跃的 CodeEdit
	var code_edit: CodeEdit = _get_code_edit("")
	if not code_edit:
		return {"success": false, "data": "No active script editor found. Please open a script first."}
	
	# 获取当前脚本路径
	var current_script: Script = EditorInterface.get_script_editor().get_current_script()
	var active_path: String = current_script.resource_path if current_script else ""
	
	# --- 文件名校验 (修复版) ---
	
	# 情况 A: 当前没有关联的 Script 资源 (可能打开的是纯文本文件)
	if active_path.is_empty():
		return {
			"success": false,
			"data": "Verification Failed: The active editor does not have a valid Script resource path.\n" +
					"Target File: '%s'\n" % expected_file_name +
					"Tip: This tool primarily supports .gd/.cs scripts. For text files, path verification may not be supported."
		}
	
	# 情况 B: 比较文件名
	var current_file_name: String = active_path.get_file()
	if current_file_name != expected_file_name:
		return {
			"success": false, 
			"data": "File mismatch error.\n" +
					"Expected: '%s' (from input '%s')\n" % [expected_file_name, raw_file_name] +
					"Active:   '%s' (%s)\n" % [current_file_name, active_path] +
					"Please use 'script_manager' to switch to the correct file."
		}
	
	# --- 安全检查 ---
	var safety_err = validate_path_safety(active_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	# --- 执行编辑 ---
	match action:
		"rewrite":
			if content.is_empty(): return {"success": false, "data": "Missing 'content'."}
			code_edit.select_all()
			code_edit.insert_text_at_caret(content)
			var sliced_view = get_sliced_code_view(code_edit)
			return {"success": true, "data": "File overwritten: %s\n\nCurrent Structure:\n%s" % [active_path, sliced_view]}
		
		"add_empty_line":
			if line_arg < 1: return {"success": false, "data": "Missing 'line'."}
			var line_count = code_edit.get_line_count()
			var target_line = line_arg - 1
			
			if target_line >= line_count:
				code_edit.set_caret_line(line_count - 1)
				code_edit.set_caret_column(code_edit.get_line(line_count - 1).length())
				code_edit.insert_text_at_caret("\n")
			else:
				code_edit.set_caret_line(target_line)
				code_edit.set_caret_column(0)
				code_edit.insert_text_at_caret("\n")
			
			var sliced_view = get_sliced_code_view(code_edit)
			return {"success": true, "data": "Added empty line at %d.\n\nCurrent Structure:\n%s" % [line_arg, sliced_view]}
		
		"insert":
			if content.is_empty(): return {"success": false, "data": "Missing 'content'."}
			if line_arg < 1: return {"success": false, "data": "Missing 'line'."}
			var target_line = min(line_arg - 1, code_edit.get_line_count())
			
			var current_line_content: String = code_edit.get_line(target_line)
			if not current_line_content.strip_edges().is_empty():
				return {"success": false, "data": "Error: Target line %d is not empty. Insert operation requires an empty line. Content: '%s'. \nTip: Use 'add_empty_line' first to create space." % [target_line + 1, current_line_content.strip_edges()]}
			
			code_edit.set_caret_line(target_line)
			code_edit.set_caret_column(0) 
			code_edit.insert_text_at_caret(content)
			
			var sliced_view = get_sliced_code_view(code_edit)
			return {"success": true, "data": "Inserted code at line %d.\n\nCurrent Structure:\n%s" % [target_line + 1, sliced_view]}
		
		"delete":
			if content.is_empty(): return {"success": false, "data": "Missing 'content' (for verification)."}
			var match_res = find_slice_by_first_line(code_edit, content)
			if not match_res.found:
				return {"success": false, "data": "Could not find a logic slice starting with: '%s'" % content}
			
			var start = match_res.start_line
			var end = match_res.end_line
			
			code_edit.select(start, 0, end, code_edit.get_line(end).length())
			var deleted_content = code_edit.get_selected_text()
			code_edit.delete_selection()
			
			var sliced_view = get_sliced_code_view(code_edit)
			
			return {"success": true, "data": "Deleted logic slice (Lines %d-%d).\n\nDeleted Content:\n```gdscript\n%s```\n\nCurrent Structure:\n%s" % [start + 1, end + 1, deleted_content, sliced_view]}
	
	return {"success": false, "data": "Unknown action: %s" % action}
