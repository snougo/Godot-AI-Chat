@tool
extends BaseSceneTool

## 当前编辑场景的树结构。外部实例与挂载脚本会标出来，避免"往实例内部加节点"这类白干。


func _init() -> void:
	tool_name = "get_edited_scene"
	tool_description = "Shows the hierarchy of the currently edited scene."


func get_parameters_schema() -> Dictionary:
	return {"type": "object", "properties": {}, "required": []}


func execute(_p_args: Dictionary) -> ToolResult:
	var root: Node = get_active_scene_root()
	if root == null:
		return ToolResult.fail("No active scene in the editor. Open one with `open_file` first.")
	
	var output: String = "%s\nroot: %s (%s)\n```\n%s\n```\n%s" % [
		scene_label(root),
		root.name,
		root.get_class(),
		get_scene_tree_string(root),
		SAVE_HINT,
	]
	
	return ToolResult.ok(output)
