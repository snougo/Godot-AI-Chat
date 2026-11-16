@tool
extends BaseSceneTool

# 查询编辑器当前打开的场景。
#
# 两个用途：
# 1. 有没有场景打开 —— 没打开时明确返回 scene: <none>，而不是让调用方从别处失败信息里猜。
# 2. 打开的是不是目标场景 —— 传 expected_scene_path 时直接给出 matches_expected 判定，
#    省去调用方自己处理 uid:// 与 res:// 的换算和逐字比较。


func _init() -> void:
	tool_name = "check_current_opened_scene"
	tool_description = "Reports which scene the editor currently has open. Use it to confirm that a scene is open at all, and (by passing expected_scene_path) whether the opened scene is the one you intend to edit."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"expected_scene_path": {
				"type": "string",
				"description": "Optional. Scene path to compare against (accepts 'res://...' or 'uid://...'). Adds a 'matches_expected: true/false' line."
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> ToolResult:
	var unknown: String = check_params(p_args, ["expected_scene_path"])
	if not unknown.is_empty():
		return ToolResult.fail(unknown)
	
	var expected: String = text_of(p_args, "expected_scene_path")
	var root: Node = get_active_scene_root()
	
	# 没场景打开也返回 ok：本工具的第一个用途就是"确认有没有打开"，这是正常答案而非工具故障。
	if root == null:
		var none_lines: PackedStringArray = PackedStringArray()
		none_lines.append("scene: <none>")
		if not expected.is_empty():
			none_lines.append("matches_expected: false")
		none_lines.append("No scene is open in the editor. Open one with `open_file` first.")
		return ToolResult.ok("\n".join(none_lines))
	
	var scene_path: String = scene_path_of(root)
	var lines: PackedStringArray = PackedStringArray()
	lines.append(scene_label(root))
	lines.append("root: %s (%s)" % [root.name, root.get_class()])
	
	if not expected.is_empty():
		var expected_path: String = _normalize_scene_reference(expected)
		if scene_path.is_empty():
			lines.append("matches_expected: false")
			lines.append("note: the opened scene has never been saved, so it cannot match '%s'." % expected_path)
		elif scene_path == expected_path:
			lines.append("matches_expected: true")
		else:
			lines.append("matches_expected: false")
			lines.append("opened: %s" % scene_path)
			lines.append("expected: %s" % expected_path)
	
	return ToolResult.ok("\n".join(lines))


# --- Private Functions ---

# 把 uid:// 换算成 res:// 路径，让两种写法都能与当前场景路径逐字比较。
# 无法换算的输入原样返回，走"不匹配"分支并原样回显，便于调用方发现写错。
static func _normalize_scene_reference(p_reference: String) -> String:
	var text: String = p_reference.strip_edges()
	if not text.begins_with("uid://"):
		return text
	
	var uid: int = ResourceUID.text_to_id(text)
	if uid == ResourceUID.INVALID_ID:
		return text
	
	var resolved: String = ResourceUID.get_id_path(uid)
	if resolved.is_empty():
		return text
	
	return resolved
