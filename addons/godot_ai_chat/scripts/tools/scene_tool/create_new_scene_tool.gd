@tool
extends BaseSceneTool

# 定义允许的扩展名白名单
const ALLOWED_EXTENSIONS = ["tscn"]

func _init() -> void:
	tool_name = "create_new_scene"
	tool_description = "Safely create a `.tscn` scene file. NEXT STEP: Use 'open_and_switch_scene' to edit it."

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"scene_path": { "type": "string", "description": "The full path where the scene file should be saved." },
			"tree_structure": {
				"type": "string",
				"description": "Markdown-Header style tree. Use '#' count for hierarchy depth.\nFormat: # NodeName (ClassName_OR_Path) {json}\nExample:\n# Main (Node3D)\n## Player (res://player.tscn) {\"position\": [10, 0, 0]}\n### Camera (Camera3D)\n## Floor (StaticBody3D)"
			}
		},
		"required": ["scene_path", "tree_structure"]
	}

func execute(args: Dictionary) -> Dictionary:
	var new_scene_path: String = args.get("scene_path", "")
	var tree_text: String = args.get("tree_structure", "")
	
	var security_error = validate_path_safety(new_scene_path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}

	var extension = new_scene_path.get_extension().to_lower()
	if extension not in ALLOWED_EXTENSIONS:
		return {"success": false, "data": "Invalid scene_path extension. Allowed: %s" % ", ".join(ALLOWED_EXTENSIONS)}
	
	if FileAccess.file_exists(new_scene_path):
		return {"success": false, "data": "File already exists: %s" % new_scene_path}
	
	var root_node: Node = null
	var node_stack: Array = [] 
	var lines: PackedStringArray = tree_text.split("\n")
	var regex := RegEx.new()
	regex.compile("^([^\\(]+)\\s*\\((.+)\\)\\s*(?:(\\{.*\\}))?$")
	
	for line in lines:
		var stripped_line: String = line.strip_edges()
		if stripped_line.is_empty(): continue
		
		var level := 0
		for char_code in stripped_line:
			if char_code == "#": level += 1
			else: break
		
		if level == 0: continue
		var content: String = stripped_line.substr(level).strip_edges()
		var match_result: RegExMatch = regex.search(content)
		if not match_result:
			_cleanup_nodes(root_node)
			return {"success": false, "data": "Parse error: '%s'" % line}
		
		var node_name: String = match_result.get_string(1).strip_edges()
		var type_str: String = match_result.get_string(2).strip_edges()
		var json_props_str: String = match_result.get_string(3).strip_edges()
		
		var new_node: Node = null
		if type_str.begins_with("res://"):
			if ResourceLoader.exists(type_str):
				var scn := ResourceLoader.load(type_str, "", ResourceLoader.CACHE_MODE_IGNORE)
				if scn is PackedScene: 
					new_node = scn.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		elif ClassDB.class_exists(type_str):
			new_node = ClassDB.instantiate(type_str)
		
		if not new_node:
			_cleanup_nodes(root_node)
			return {"success": false, "data": "Invalid Class/Path: '%s'" % type_str}
		
		new_node.name = node_name
		
		if not json_props_str.is_empty():
			var json := JSON.new()
			if json.parse(json_props_str) == OK and json.data is Dictionary:
				apply_properties(new_node, json.data)
		
		if node_stack.is_empty():
			root_node = new_node
			node_stack.append({"node": new_node, "level": level})
		else:
			while not node_stack.is_empty() and node_stack.back()["level"] >= level:
				node_stack.pop_back()
			if node_stack.is_empty():
				new_node.free()
				_cleanup_nodes(root_node)
				return {"success": false, "data": "Hierarchy error at %s" % node_name}
			node_stack.back()["node"].add_child(new_node)
			node_stack.append({"node": new_node, "level": level})
	
	if not root_node: return {"success": false, "data": "Empty tree."}
	
	set_owner_recursive(root_node, root_node)
	var packed_scene = PackedScene.new()
	packed_scene.pack(root_node)
	
	var base_dir: String = new_scene_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(base_dir):
		if is_instance_valid(root_node):
			root_node.free()
		return {"success": false, "data": "Directory not found: %s. Please use 'create_folder' tool first." % base_dir}
	
	var err = ResourceSaver.save(packed_scene, new_scene_path)
	
	if is_instance_valid(root_node):
		root_node.free()
	
	if err == OK:
		ToolBox.update_editor_filesystem(new_scene_path)
		return {"success": true, "data": "Scene created at %s" % new_scene_path}
	else:
		return {"success": false, "data": "Save Failed: %d" % err}

func _cleanup_nodes(node: Node):
	if node and is_instance_valid(node): node.free()
