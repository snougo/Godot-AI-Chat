@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "manage_scene_file"
	tool_description = "Creates new scene file, opens existing one, or switches between currently open scenes in the editor."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["open", "create", "switch"],
				"description": "The action to perform."
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
	
	# Common Validation
	if scene_path.is_empty():
		return {"success": false, "data": "scene_path is required."}
	
	# 1. Security Check (Path Blacklist)
	var safety_err: String = validate_path_safety(scene_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	# 2. Extension Check
	var ext: String = scene_path.get_extension().to_lower()
	if ext != "tscn":
		return {"success": false, "data": "Invalid file extension '%s'. Allowed extensions: .tscn, .scn" % ext}
	
	match action:
		"open", "switch":
			if not FileAccess.file_exists(scene_path):
				return {"success": false, "data": "File not found: %s" % scene_path}
			
			# EditorInterface handles switching automatically if already open
			EditorInterface.open_scene_from_path(scene_path)
			return {"success": true, "data": "Opened/Switched to scene: %s" % scene_path}
		
		"create":
			return _execute_create(p_args, scene_path)
	
	return {"success": false, "data": "Unknown action: %s" % action}


func _execute_create(p_args: Dictionary, p_path: String) -> Dictionary:
	if FileAccess.file_exists(p_path):
		return {"success": false, "data": "File already exists: %s" % p_path}
	
	var type: String = p_args.get("root_node_type", "Node")
	var name: String = p_args.get("root_node_name", "")
	if name.is_empty():
		name = p_path.get_file().get_basename()
	
	var root: Node = instantiate_node_from_type(type)
	if not root:
		return {"success": false, "data": "Invalid root class/type: %s" % type}
	
	root.name = name
	var packed: PackedScene = PackedScene.new()
	var pack_result := packed.pack(root)
	
	if pack_result != OK:
		root.free()
		return {"success": false, "data": "Failed to pack scene: %d" % pack_result}
		
	var err: Error = ResourceSaver.save(packed, p_path)
	
	if is_instance_valid(root):
		root.free()
	
	if err == OK:
		# Force filesystem scan to ensure the new file is recognized by the editor
		ToolBox.update_editor_filesystem(p_path)
		return {"success": true, "data": "Scene Created: %s, Using `open` to open scene" % p_path}
		
	return {"success": false, "data": "Failed to save scene: %d" % err}
