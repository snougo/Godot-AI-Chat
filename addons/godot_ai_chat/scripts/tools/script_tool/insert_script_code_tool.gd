@tool
extends BaseScriptTool

func _init() -> void:
	tool_name = "insert_script_code"
	tool_description = "Inserts code into a slice. REQUIRES 'slice_index' from 'get_current_active_script'."

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "The full path to the script file."
			},
			"new_code": {
				"type": "string",
				"description": "The GDScript code to insert."
			},
			"slice_index": {
				"type": "integer",
				"description": "The 0-based index of the logical slice (e.g., function block) to search in."
			},
			"anchor_code": {
				"type": "string",
				"description": "The EXACT code snippet in the slice to use as a reference point."
			},
			"insert_position": {
				"type": "string",
				"enum": ["after", "before"],
				"description": "Insert 'after' (default) or 'before' the anchor code."
			}
		},
		"required": ["path", "new_code", "slice_index", "anchor_code"]
	}

func execute(args: Dictionary) -> Dictionary:
	var path = args.get("path", "")
	var new_code = args.get("new_code", "")
	var slice_index = args.get("slice_index", -1)
	var anchor_code = args.get("anchor_code", "")
	var insert_pos = args.get("insert_position", "after")
	
	# --- 1. 安全与基本检查 ---
	var security_error = validate_path_safety(path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	if not FileAccess.file_exists(path):
		return {"success": false, "data": "File not found: " + path}
	
	if slice_index < 0:
		return {"success": false, "data": "Invalid slice_index. Must be >= 0."}
		
	if anchor_code.strip_edges().is_empty():
		return {"success": false, "data": "anchor_code cannot be empty."}

	# --- 2. 加载编辑器 ---
	var res = load(path)
	if not res is Script:
		return {"success": false, "data": "Resource is not a script."}
	
	EditorInterface.edit_resource(res)
	var script_editor = EditorInterface.get_script_editor()
	var current_editor = script_editor.get_current_editor()
	if not current_editor:
		return {"success": false, "data": "Could not access script editor."}
	var base_editor = current_editor.get_base_editor()
	
	# --- 3. 切片定位 (基类) ---
	# 获取当前编辑器文本进行实时解析
	var current_text = base_editor.text
	var slices = _parse_script_to_slices(current_text)
	
	if slice_index >= slices.size():
		return {"success": false, "data": "slice_index %d out of bounds. Total slices: %d" % [slice_index, slices.size()]}
	
	var target_slice = slices[slice_index]
	
	# --- 4. 寻找锚点 (基类) ---
	var anchor_match = _find_code_in_slice(base_editor, target_slice, anchor_code)
	
	if not anchor_match.found:
		var msg = "Could not find 'anchor_code' in slice %d.\n" % slice_index
		msg += "Slice Context (Lines %d-%d):\n%s\n...\n" % [target_slice.start_line + 1, target_slice.end_line + 1, _get_preview_lines(base_editor, target_slice, 5)]
		msg += "ACTION: Verify 'anchor_code' exists in this slice."
		return {"success": false, "data": msg}
	
	# --- 5. 计算插入行号 ---
	var insertion_line_index = -1
	if insert_pos == "before":
		insertion_line_index = anchor_match.start_line
	else:
		insertion_line_index = anchor_match.end_line + 1
	
	# --- 6. 执行插入 ---
	if base_editor.has_method("begin_complex_operation"):
		base_editor.begin_complex_operation()
	
	if not new_code.ends_with("\n"):
		new_code += "\n"
	
	# 智能缩进 (基类)
	var indent = _get_indentation(base_editor.get_line(anchor_match.start_line))
	new_code = _apply_indentation(new_code, indent)
	
	base_editor.insert_text(new_code, insertion_line_index, 0)
	
	if base_editor.has_method("end_complex_operation"):
		base_editor.end_complex_operation()
	
	return {
		"success": true, 
		"data": "Successfully inserted code %s slice %d (Line %d)." % [insert_pos, slice_index, insertion_line_index + 1]
	}
