@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "check_node_properties"
	tool_description = "Gets detailed information about a node in the current edited scene, including its properties and children."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Target node path (use '.' for root). Defaults to root."
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
		return {"success": false, "data": "Node not found: %s" % node_path}
	
	var info: Dictionary = {
		"name": target.name,
		"class": target.get_class(),
		"children": [],
		"properties": {}
	}
	
	for c in target.get_children():
		info.children.append("%s (%s)" % [c.name, c.get_class()])
	
	for p in target.get_property_list():
		if p.usage & PROPERTY_USAGE_EDITOR:
			info.properties[p.name] = str(target.get(p.name))
	
	return {"success": true, "data": info}
