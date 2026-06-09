@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "batch_edit"
	tool_description = "Batch-edit the current script with insert/delete/replace. All line numbers reference the original file. See `primers/batch_edit_tool_guide.md` for detailed rules and examples."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"operations": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"type": {
							"type": "string",
							"enum": ["insert", "delete", "replace"],
							"description": "Type of edit operation."
						},
						"target_line": {
							"type": "integer",
							"description": "For 'insert' only. Insert content AFTER this line (1-based)."
						},
						"start_line": {
							"type": "integer",
							"description": "For 'delete' and 'replace' only. Start line (1-based, inclusive)."
						},
						"end_line": {
							"type": "integer",
							"description": "For 'delete' and 'replace' only. End line (1-based, inclusive)."
						},
						"content": {
							"type": "string",
							"description": "For 'insert' and 'replace' only. The new code content (may contain \\n for multiple lines)."
						}
					},
					"required": ["type"]
				},
				"description": "Array of edit operations to apply."
			}
		},
		"required": ["operations"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var operations: Array = p_args.get("operations", [])
	if operations.is_empty():
		return {"success": false, "data": "No operations provided."}
	
	var code_edit := _get_code_edit("")
	if not code_edit:
		return {"success": false, "data": "No active script editor."}
	
	# Step 1: Read original lines
	var total_lines := code_edit.get_line_count()
	var lines: Array[String] = []
	for i in range(total_lines):
		lines.append(code_edit.get_line(i))
	
	# Step 2: Validate all operations
	var validation_error := _validate_operations(operations, total_lines)
	if not validation_error.is_empty():
		return {"success": false, "data": "Validation failed:\n" + validation_error}
	
	# Step 3: Sort operations by position (stable: same position keeps original order)
	var sorted_ops := _sort_operations(operations)
	
	# Step 4: Apply cut-and-stitch algorithm
	var result_lines := _apply_operations(lines, sorted_ops)
	
	# Step 5: Write back to editor
	var new_content: String = "\n".join(result_lines)
	code_edit.text = new_content
	
	# Step 6: Return preview
	var view := get_full_script_with_line_numbers(code_edit)
	return {"success": true, "data": "Batch edit completed (%d operations).\n\n%s" % [operations.size(), view]}


# --- Private Functions ---

# 验证所有操作：行号边界 + 重叠检测
func _validate_operations(p_ops: Array, p_total_lines: int) -> String:
	# 记录每个操作的范围 [索引, 类型, 起始行, 结束行]
	var ranges: Array[Dictionary] = []
	
	for i in range(p_ops.size()):
		var op: Dictionary = p_ops[i]
		var op_type: String = op.get("type", "")
		
		match op_type:
			"insert":
				var target: int = op.get("target_line", 0)
				if target < 1 or target > p_total_lines:
					return "Operation %d (insert): target_line %d is out of range. Valid: 1-%d." % [i + 1, target, p_total_lines]
				if not op.has("content"):
					return "Operation %d (insert): Missing 'content' field." % [i + 1]
				ranges.append({"index": i, "type": "insert", "start": target, "end": target})
			
			"delete":
				var s: int = op.get("start_line", 0)
				var e: int = op.get("end_line", 0)
				if s < 1 or e < 1 or s > p_total_lines or e > p_total_lines:
					return "Operation %d (delete): Line range out of bounds. Valid: 1-%d, got [%d, %d]." % [i + 1, p_total_lines, s, e]
				if s > e:
					return "Operation %d (delete): start_line (%d) > end_line (%d)." % [i + 1, s, e]
				ranges.append({"index": i, "type": "delete", "start": s, "end": e})
			
			"replace":
				var s: int = op.get("start_line", 0)
				var e: int = op.get("end_line", 0)
				if s < 1 or e < 1 or s > p_total_lines or e > p_total_lines:
					return "Operation %d (replace): Line range out of bounds. Valid: 1-%d, got [%d, %d]." % [i + 1, p_total_lines, s, e]
				if s > e:
					return "Operation %d (replace): start_line (%d) > end_line (%d)." % [i + 1, s, e]
				if not op.has("content"):
					return "Operation %d (replace): Missing 'content' field." % [i + 1]
				ranges.append({"index": i, "type": "replace", "start": s, "end": e})
			
			_:
				return "Operation %d: Unknown type '%s'. Must be 'insert', 'delete', or 'replace'." % [i + 1, op_type]
	
	# 重叠检测
	for i in range(ranges.size()):
		for j in range(i + 1, ranges.size()):
			var a := ranges[i]
			var b := ranges[j]
			
			# 同一位置多个 insert 允许
			if a["type"] == "insert" and b["type"] == "insert" and a["start"] == b["start"]:
				continue
			
			# 重叠条件：a_start <= b_end AND b_start <= a_end
			if a["start"] <= b["end"] and b["start"] <= a["end"]:
				return "Operation %d (%s) and operation %d (%s) overlap: [%d, %d] ∩ [%d, %d]. Overlapping operations are not allowed." % [
					a["index"] + 1, a["type"],
					b["index"] + 1, b["type"],
					a["start"], a["end"],
					b["start"], b["end"]
				]
	
	return ""


# 稳定排序：按位置升序，同位置保持原顺序
func _sort_operations(p_ops: Array) -> Array:
	var ops_with_order: Array[Dictionary] = []
	
	for i in range(p_ops.size()):
		var op: Dictionary = p_ops[i].duplicate()
		var pos: int
		match op.get("type", ""):
			"insert":
				pos = op.get("target_line", 0)
			"delete", "replace":
				pos = op.get("start_line", 0)
		op["_sort_pos"] = pos
		op["_sort_idx"] = i
		ops_with_order.append(op)
	
	ops_with_order.sort_custom(func(a, b):
		if a["_sort_pos"] != b["_sort_pos"]:
			return a["_sort_pos"] < b["_sort_pos"]
		return a["_sort_idx"] < b["_sort_idx"]
	)
	
	var result: Array = []
	for op in ops_with_order:
		op.erase("_sort_pos")
		op.erase("_sort_idx")
		result.append(op)
	
	return result


# 核心切割-缝合算法
# 所有操作基于原始行号，互不干扰
func _apply_operations(p_lines: Array[String], p_ops: Array) -> Array[String]:
	var result: Array[String] = []
	var cursor_1based := 1  # 指向下一个待复制的原始行（1-based）
	
	for op in p_ops:
		var op_type: String = op.get("type", "")
		
		match op_type:
			"insert":
				var target: int = op.get("target_line", 0)
				var content: String = op.get("content", "")
				
				# 复制到 target_line（含）
				while cursor_1based <= target:
					result.append(p_lines[cursor_1based - 1])
					cursor_1based += 1
				
				# 插入新内容
				content = content.trim_suffix("\n")
				if not content.is_empty():
					result.append(content)
			
			"delete":
				var s: int = op.get("start_line", 0)
				var e: int = op.get("end_line", 0)
				
				# 复制到 start_line 之前
				while cursor_1based < s:
					result.append(p_lines[cursor_1based - 1])
					cursor_1based += 1
				
				# 跳过被删行
				cursor_1based = e + 1
			
			"replace":
				var s: int = op.get("start_line", 0)
				var e: int = op.get("end_line", 0)
				var content: String = op.get("content", "")
				
				# 复制到 start_line 之前
				while cursor_1based < s:
					result.append(p_lines[cursor_1based - 1])
					cursor_1based += 1
				
				# 跳过被替换行
				cursor_1based = e + 1
				
				# 插入新内容
				content = content.trim_suffix("\n")
				if not content.is_empty():
					result.append(content)
	
	# 复制剩余行
	while cursor_1based <= p_lines.size():
		result.append(p_lines[cursor_1based - 1])
		cursor_1based += 1
	
	return result
