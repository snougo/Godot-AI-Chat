@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "get_scene_node_properties"
	tool_description = "Gets all properties of a target node, including nested Resource properties."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Target node path."
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> Dictionary:
	var root: Node = get_active_scene_root()
	if not root:
		return {"success": false, "data": "No active scene."}
	
	var node_path: String = p_args.get("node_path", ".")
	var target: Node = get_node_from_root(root, node_path)
	
	if not target:
		var hint = get_node_path_error_hint(root, node_path)
		return {"success": false, "data": hint}
	
	# 返回完整节点属性（含 Resource）
	var all_properties := get_all_node_properties(target)
	
	return {"success": true, "data": all_properties}
