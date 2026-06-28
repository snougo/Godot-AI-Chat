@tool
extends BaseScriptTool


func _init() -> void:
	tool_name = "multi_replace"
	tool_description = "Multi-replace in the current script. Each operation searches for exact text matches and replaces all occurrences with new content. All searches are based on the original file content. Unmatched searches are skipped with a warning."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"operations": {
				"type": "array",
				"items": {
					"type": "object",
					"properties": {
						"search": {
							"type": "string",
							"description": "Exact text to search for (multi-line supported with \\n). All non-overlapping occurrences will be replaced."
						},
						"content": {
							"type": "string",
							"description": "Replacement text (multi-line supported with \\n)."
						}
					},
					"required": ["search", "content"]
				},
				"description": "Array of replace operations."
			}
		},
		"required": ["operations"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var operations: Array = p_args.get("operations", [])
	if operations.is_empty():
		return ToolResult.fail("No operations provided.")

	var code_edit := _get_code_edit("")
	if not code_edit:
		return ToolResult.fail("No active script editor.")

	# Step 1: Read original full text
	var total_lines := code_edit.get_line_count()
	var original_lines: Array[String] = []
	for i in range(total_lines):
		original_lines.append(code_edit.get_line(i))
	var original_text: String = "\n".join(original_lines)

	# Step 2: Find all occurrences for each operation
	var all_occurrences: Array[Dictionary] = []  # {op_idx, start, end, content}
	var skipped: Array[String] = []

	for i in range(operations.size()):
		var op: Dictionary = operations[i]
		var search_text: String = op.get("search", "")
		var replace_text: String = op.get("content", "")

		if search_text.is_empty():
			skipped.append("Operation %d: 'search' is empty, skipped." % [i + 1])
			continue

		var occurrences := _find_all_occurrences(original_text, search_text)
		if occurrences.is_empty():
			skipped.append("Operation %d: search text not found, skipped." % [i + 1])
			continue

		for occ in occurrences:
			all_occurrences.append({
				"op_idx": i,
				"start": occ.start,
				"end": occ.end,
				"content": replace_text
			})

	if all_occurrences.is_empty():
		var msg: String = "No replacements performed."
		if not skipped.is_empty():
			msg += "\n" + "\n".join(skipped)
		return ToolResult.fail(msg)

	# Step 3: Validate cross-operation overlaps
	var overlap_error := _validate_overlaps(all_occurrences)
	if not overlap_error.is_empty():
		return ToolResult.fail(overlap_error)

	# Step 4: Sort by start position
	all_occurrences.sort_custom(func(a, b):
		if a.start != b.start:
			return a.start < b.start
		return a.op_idx < b.op_idx
	)

	# Step 5: Apply cut-and-stitch
	var result_parts: Array[String] = []
	var cursor: int = 0

	for occ in all_occurrences:
		# Copy text before this occurrence
		if cursor < occ.start:
			result_parts.append(original_text.substr(cursor, occ.start - cursor))
		# Replace with new content
		result_parts.append(occ.content)
		cursor = occ.end

	# Append remaining text
	if cursor < original_text.length():
		result_parts.append(original_text.substr(cursor))

	var new_text: String = "".join(result_parts)

	# Step 6: Write back
	code_edit.text = new_text

	# Step 7: Build report
	var report: String = "Multi-replace completed (%d replacements in %d operations)." % [all_occurrences.size(), operations.size()]
	if not skipped.is_empty():
		report += "\n\nSkipped:\n" + "\n".join(skipped)

	var view := get_full_script_with_line_numbers(code_edit)
	report += "\n\n" + view

	return ToolResult.ok(report)


# --- Private Functions ---

## 在文本中查找所有不重叠的出现位置
func _find_all_occurrences(p_text: String, p_search: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var pos: int = 0
	var search_len: int = p_search.length()

	while pos < p_text.length():
		var found: int = p_text.find(p_search, pos)
		if found == -1:
			break
		result.append({"start": found, "end": found + search_len})
		pos = found + search_len  # 确保不重叠

	return result


## 验证不同操作之间的匹配区域是否重叠
func _validate_overlaps(p_occurrences: Array[Dictionary]) -> String:
	for i in range(p_occurrences.size()):
		for j in range(i + 1, p_occurrences.size()):
			var a := p_occurrences[i]
			var b := p_occurrences[j]

			# 同一操作的不同出现，允许
			if a.op_idx == b.op_idx:
				continue

			# 重叠条件: a_start < b_end AND b_start < a_end
			if a.start < b.end and b.start < a.end:
				return "Operation %d and operation %d overlap at character range [%d, %d) ∩ [%d, %d). Overlapping replacements are not allowed." % [
					a.op_idx + 1, b.op_idx + 1,
					a.start, a.end,
					b.start, b.end
				]

	return ""
