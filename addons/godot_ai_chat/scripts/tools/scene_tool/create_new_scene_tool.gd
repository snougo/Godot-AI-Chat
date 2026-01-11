@tool
extends BaseSceneTool

# 路径黑名单
const PATH_BLACKLIST = [
	"/.git/", 
	"/.import/", 
	"/.godot/",
	"/android/", 
	"/addons/"
]


func _init() -> void:
	tool_name = "create_new_scene"
	tool_description = "Safely create a `.tscn` scene file. Supports built-in classes and .tscn instantiation."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"scene_path": { "type": "string", "description": "The full 'res://' path where the .tscn file should be saved." },
			"tree_structure": {
				"type": "string",
				"description": "Markdown-Header style tree. Use '#' count for hierarchy depth.\nFormat: # NodeName (ClassName_OR_Path) {json}\nExample:\n# Main (Node3D)\n## Player (res://player.tscn) {\"position\": [10, 0, 0]}\n### Camera (Camera3D)\n## Floor (StaticBody3D)"
			}
		},
		"required": ["scene_path", "tree_structure"]
	}


func execute(args: Dictionary, _context_provider: Object) -> Dictionary:
	var scene_path: String = args.get("scene_path", "")
	var tree_text: String = args.get("tree_structure", "")
	
	# 路径和文件格式检查
	if not scene_path.begins_with("res://") or not scene_path.ends_with(".tscn"):
		return {"success": false, "data": "Invalid scene_path. Must start with 'res://' and end with '.tscn'."}
	
	# 黑名单路径检查
	for blocked_path in PATH_BLACKLIST:
		if scene_path.contains(blocked_path):
			return {"success": false, "data": "Security Error: Saving to restricted directory '%s' is not allowed." % blocked_path}
	
	# 同名文件检查
	if FileAccess.file_exists(scene_path):
		return {"success": false, "data": "File already exists: %s" % scene_path}
	
	var root_node: Node = null
	var node_stack: Array = [] 
	var lines: PackedStringArray = tree_text.split("\n")
	var regex := RegEx.new()
	regex.compile("^([a-zA-Z0-9_]+)\\s*\\(([^)]+)\\)\\s*(?:(\\{.*\\}))?$")
	
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
		
		var node_name: String = match_result.get_string(1)
		var type_str: String = match_result.get_string(2)
		var json_props_str: String = match_result.get_string(3)
		
		var new_node: Node = null
		if type_str.begins_with("res://"):
			if ResourceLoader.exists(type_str):
				# 强制忽略缓存，防止读取到内存中已损坏的资源
				var scn := ResourceLoader.load(type_str, "", ResourceLoader.CACHE_MODE_IGNORE)
				if scn is PackedScene: 
					# 使用 GEN_EDIT_STATE_INSTANCE，确保编辑器元数据正确
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
				# 使用 BaseSceneTool 的批量应用方法，它会自动处理类型转换
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
	
	if not DirAccess.dir_exists_absolute(scene_path.get_base_dir()):
		DirAccess.make_dir_recursive_absolute(scene_path.get_base_dir())
	
	var err = ResourceSaver.save(packed_scene, scene_path)
	if is_instance_valid(root_node):
		root_node.free()
	
	if err == OK:
		if Engine.is_editor_hint():
			# 使用 update_file 强制更新该文件的元数据，解决 UID 识别错误
			EditorInterface.get_resource_filesystem().update_file(scene_path)
			# 保留 scan 以确保可能的新建目录被识别
			#EditorInterface.get_resource_filesystem().scan()
		return {"success": true, "data": "Scene created at %s" % scene_path}
	else:
		return {"success": false, "data": "Save Failed: %d" % err}


func _cleanup_nodes(node: Node):
	if node and is_instance_valid(node): node.free()
