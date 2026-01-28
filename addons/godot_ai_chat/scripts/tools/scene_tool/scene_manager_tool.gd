@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "scene_manager"
	tool_description = "Manage scene files: create new scenes, open existing ones, switch between open scenes, and save the current scene."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["open", "create", "switch"],
				"description": "The action to perform. 'switch' is synonymous with 'open' for already open scenes."
			},
			"scene_path": {
				"type": "string",
				"description": "Full path to the .tscn file. Required for 'create', 'open', 'switch'."
			},
			"root_node_type": {
				"type": "string",
				"description": "The class name of the root node for 'create' . Default is 'Node'."
			},
			"root_node_name": {
				"type": "string",
				"description": "The name of the root node for 'create'. Defaults to file basename."
			}
		},
		"required": ["action"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var action: String = p_args.get("action", "")
	var scene_path: String = p_args.get("scene_path", "")
	
	match action:
		"open", "switch":
			if scene_path.is_empty():
				return {"success": false, "data": "scene_path is required for '%s'." % action}
			if not FileAccess.file_exists(scene_path):
				return {"success": false, "data": "File not found: %s" % scene_path}
			
			# EditorInterface handles switching automatically if already open
			EditorInterface.open_scene_from_path(scene_path)
			return {"success": true, "data": "Opened/Switched to scene: %s" % scene_path}
		
		"create":
			return _execute_create(p_args)
	
	return {"success": false, "data": "Unknown action: %s" % action}


func _execute_create(p_args: Dictionary) -> Dictionary:
	var path: String = p_args.get("scene_path", "")
	if path.is_empty():
		return {"success": false, "data": "scene_path required for create."}
	if FileAccess.file_exists(path):
		return {"success": false, "data": "File already exists: %s" % path}
	
	var type: String = p_args.get("root_node_type", "Node")
	var name: String = p_args.get("root_node_name", "")
	if name.is_empty():
		name = path.get_file().get_basename()
	
	var root: Node = _instantiate_node(type)
	if not root:
		return {"success": false, "data": "Invalid root class/type: %s" % type}
	
	root.name = name
	var packed = PackedScene.new()
	packed.pack(root)
	var err = ResourceSaver.save(packed, path)
	root.free()
	
	if err == OK:
		EditorInterface.open_scene_from_path(path)
		return {"success": true, "data": "Created and opened scene: %s" % path}
	return {"success": false, "data": "Failed to save scene: %d" % err}


func _instantiate_node(type_str: String) -> Node:
	if type_str.begins_with("res://"):
		if ResourceLoader.exists(type_str):
			var res = load(type_str)
			if res is PackedScene:
				return res.instantiate()
	elif ClassDB.class_exists(type_str):
		return ClassDB.instantiate(type_str)
	return null
