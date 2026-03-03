@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "check_node_properties"
	tool_description = "Gets detailed information about a node in the current edited scene, including its properties and children (with Resource details)."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Target node path (e.g., 'RootNode/ChildNode'). Use absolute paths from scene tree root."
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
		# ✅ 优化：提供当前场景树结构和路径建议
		var scene_tree: String = get_scene_tree_string(root)
		var suggestions: Array[String] = find_similar_paths(root, node_path)
		var suggestion_text: String = ""
		
		if not suggestions.is_empty():
			suggestion_text = "\n\nDid you mean:\n  - " + "\n  - ".join(suggestions)
		
		return {
			"success": false, 
			"data": "Node not found: %s\n\nCurrent Scene Tree:\n%s%s" % [node_path, scene_tree, suggestion_text]
		}
	
	# 返回完整节点属性（含 Resource）
	var all_properties := get_all_node_properties(target)
	
	return {"success": true, "data": all_properties}
