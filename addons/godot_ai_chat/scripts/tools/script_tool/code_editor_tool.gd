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
				"enum": ["rewrite", "insert", "replace"],
				"description": "The editing action."
			},
			"content": {
				"type": "string",
				"description": "Code content to write."
			},
			"line": {
				"type": "integer",
				"description": "Start line (1-based). Required for insert/replace."
			},
			"column": {
				"type": "integer",
				"description": "Start column (1-based). Default 1."
			},
			"to_line": {
				"type": "integer",
				"description": "End line (1-based). Required for replace."
			},
			"to_column": {
				"type": "integer",
				"description": "End column (1-based). Required for replace."
			}
		},
		"required": ["action", "content"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")
	var content: String = p_args.get("content", "")
	var line_arg: int = p_args.get("line", 0)
	var col_arg: int = p_args.get("column", 1)
	var to_line_arg: int = p_args.get("to_line", 0)
	var to_col_arg: int = p_args.get("to_column", 0)
	
	# 获取当前活跃的 CodeEdit (传入空字符串即获取当前)
	var code_edit: CodeEdit = _get_code_edit("")
	if not code_edit:
		return {"success": false, "data": "No active script editor found. Please open a script first."}
	
	# 获取当前脚本路径
	var current_script: Script = EditorInterface.get_script_editor().get_current_script()
	var active_path: String = current_script.resource_path if current_script else ""
	
	# --- 安全检查 ---
	# 即使是当前打开的文件，也必须通过安全检查（防止编辑被禁止的系统文件或插件核心文件）
	if not active_path.is_empty():
		var safety_err = validate_path_safety(active_path)
		if not safety_err.is_empty():
			return {"success": false, "data": safety_err}
		var ext_err = validate_file_extension(active_path)
		if not ext_err.is_empty():
			return {"success": false, "data": ext_err}
	else:
		# 如果脚本没有路径（例如未保存的新文件），通常是临时文件，视为允许操作
		pass
	
	match action:
		"rewrite":
			code_edit.select_all()
			code_edit.insert_text_at_caret(content)
			return {"success": true, "data": "File overwritten: %s" % active_path}
		
		"insert":
			if line_arg < 1: return {"success": false, "data": "Missing 'line'."}
			var target_line = min(line_arg - 1, code_edit.get_line_count())
			code_edit.set_caret_line(target_line)
			code_edit.set_caret_column(col_arg - 1)
			code_edit.insert_text_at_caret(content)
			var snapshot = get_code_snapshot(code_edit, target_line)
			return {"success": true, "data": "Inserted code at %d:%d.\n%s" % [target_line + 1, col_arg, snapshot]}
		
		"replace":
			if line_arg < 1 or to_line_arg < 1: return {"success": false, "data": "Missing 'line'/'to_line'."}
			code_edit.select(line_arg - 1, col_arg - 1, to_line_arg - 1, to_col_arg - 1)
			code_edit.insert_text_at_caret(content)
			var snapshot = get_code_snapshot(code_edit, line_arg - 1)
			return {"success": true, "data": "Replaced code range.\n%s" % snapshot}
	
	return {"success": false, "data": "Unknown action: %s" % action}
