@tool
extends BaseSceneTool

## 设置一个属性。property 是节点自身属性，资源上的子属性用 sub_path（字符串数组）。
## value 优先用原生 JSON 类型；字符串写法也接受（"Vector3(1,2,3)"、"#ff0000"、"new:SphereShape3D"…）。


func _init() -> void:
	tool_name = "set_scene_node_properties"
	tool_description = "Sets one property on a node with type validation."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Target node, e.g. 'xxx/xxxx' or '.' for the root."
			},
			"property": {
				"type": "string",
				"description": "Node property name."
			},
			"sub_path": {
				"type": "array",
				"items": {"type": "string"},
				"description": "For a property of a resource: the path inside it, e.g. [\"material\", \"albedo_color\"]. Replaces the ':' notation."
			},
			"value": {
				"type": "string",
				"description": "New value. Prefer JSON text: [1,2,3] for Vector3, true, 3.5, \"#ff8800\" for Color, \"res://x.tres\" or \"new:SphereShape3D\" for a Resource, \"null\" to clear. Native JSON values are accepted too when the provider passes them through."
			},
			"save": {
				"type": "boolean",
				"description": "Also write the scene to disk. Default false."
			},
			"verbose": {
				"type": "boolean",
				"description": "Include the whole scene tree in the reply. Default false."
			}
		},
		"required": ["node_path", "property", "value"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var root: Node = get_active_scene_root()
	if root == null:
		return ToolResult.fail("No active scene in the editor. Open one with `open_file` first.")
	
	return finish_edit(root, do_set_property(root, p_args), p_args)
