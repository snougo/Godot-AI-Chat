@tool
extends BaseSceneTool

## 读一个节点的属性。默认只给"字符串值 + 类型"：更省 token，也避免 JSON 把原生值退化成重复文本。


func _init() -> void:
	tool_name = "get_scene_node_properties"
	tool_description = "Lists the editor-visible properties of a node: value, type, and the resource it points to."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Target node, e.g. 'xxx/xxxx' or '.' for the root."
			},
			"include_raw": {
				"type": "boolean",
				"description": "Also return each value in JSON-safe form (Vector3 as [x,y,z], Color as #RRGGBBAA). Default false."
			},
			"include_resources": {
				"type": "boolean",
				"description": "Also list the editable properties of each attached resource. Default false."
			}
		},
		"required": ["node_path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var root: Node = get_active_scene_root()
	if root == null:
		return ToolResult.fail("No active scene in the editor. Open one with `open_file` first.")
	
	var unknown: String = check_params(p_args, ["node_path", "include_raw", "include_resources"])
	if not unknown.is_empty():
		return ToolResult.fail(unknown)
	
	if not p_args.has("node_path") or text_of(p_args, "node_path").is_empty():
		return ToolResult.fail("'node_path' is required. Use \".\" for the scene root.")
	
	var resolved: Dictionary = resolve_node(root, text_of(p_args, "node_path"))
	if resolved.node == null:
		return ToolResult.fail(str(resolved.error))
	
	var node: Node = resolved.node
	var output: Dictionary = {
		"scene": scene_path_of(root),
		"node_path": node_path_of(root, node),
		"class": node.get_class(),
		"properties": get_all_node_properties(node, flag_of(p_args, "include_raw"), flag_of(p_args, "include_resources")),
	}
	
	return ToolResult.ok(JSON.stringify(output, "\t"))
