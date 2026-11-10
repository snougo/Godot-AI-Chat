@tool
extends BaseSceneTool

## 新建场景文件。可一次给出整棵子树 + 初始属性，避免"create_scene + N 次 add_node"的往返。


func _init() -> void:
	tool_name = "create_scene"
	tool_description = "Creates a new .tscn: root node plus an optional ordered list of child nodes with initial properties."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Target folder. It must already exist."
			},
			"file_name": {
				"type": "string",
				"description": "File name ending in .tscn, e.g. 'xxxxx.tscn'. Existing files are never overwritten."
			},
			"root_node_type": {
				"type": "string",
				"description": "Root class, e.g. 'Node2D', 'Node3D', 'Control'...etc, Default 'Node'."
			},
			"root_node_name": {
				"type": "string",
				"description": "Root node name. Default: the file base name."
			},
			"nodes": {
				"type": "array",
				"items": {"type": "object"},
				"description": "Optional children, parent-first. Each: "
					+ "{\"node_path\":\"Player/Body\",\"node_type\":\"CollisionShape3D\"}, "
					+ "{\"node_path\":\"Player\",\"scene_path\":\"res://actors/player.tscn\"}, "
					+ "{\"node_path\":\"Label\",\"node_type\":\"Label\",\"properties\":{\"text\":\"Hello\",\"position\":\"[10,20]\"}}. "
					+ "node_path is relative to the new root; a parent must appear earlier in the list."
			}
		},
		"required": ["path", "file_name"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var unknown: String = check_params(p_args, ["path", "file_name", "root_node_type", "root_node_name", "nodes"])
	if not unknown.is_empty():
		return ToolResult.fail(unknown)
	var folder: String = text_of(p_args, "path")
	var file_name: String = text_of(p_args, "file_name")
	if folder.is_empty() or file_name.is_empty():
		return ToolResult.fail("'path' (folder) and 'file_name' are required.")
	if not folder.begins_with("res://"):
		return ToolResult.fail("'path' must start with res://.")
	if not folder.ends_with("/"):
		folder += "/"
	if not file_name.ends_with(".tscn"):
		return ToolResult.fail("'file_name' must end with .tscn (got '%s')." % file_name)
	var full_path: String = folder + file_name
	var safety: String = validate_path_safety(full_path)
	if not safety.is_empty():
		return ToolResult.fail(safety)
	if FileAccess.file_exists(full_path):
		return ToolResult.fail("File already exists: %s. Overwriting is not allowed — open and edit it instead." % full_path)
	if not DirAccess.dir_exists_absolute(folder):
		return ToolResult.fail("Folder does not exist: %s. Create it first." % folder)

	var root_type: String = text_of(p_args, "root_node_type", "Node")
	var root: Node = instantiate_by_class(root_type)
	if root == null:
		return ToolResult.fail("'%s' is not an instantiable Node class.%s" % [root_type, candidate_suffix(class_candidates(root_type))])
	var root_name: String = text_of(p_args, "root_node_name")
	if root_name.is_empty():
		root_name = file_name.get_basename()
	root.name = root_name.validate_node_name()
	if str(root.name).is_empty():
		root.name = "Root"

	var made: Dictionary = {".": root}
	var entries: Variant = p_args.get("nodes")
	if entries != null and not (entries is Array):
		root.free()
		return ToolResult.fail("'nodes' must be an array of objects.")
	if entries is Array:
		var list: Array = entries
		for index in range(list.size()):
			var problem: String = _build_child(root, made, list[index], index)
			if not problem.is_empty():
				root.free()
				return ToolResult.fail(problem)

	var packed: PackedScene = PackedScene.new()
	var pack_error: Error = packed.pack(root)
	if pack_error != OK:
		root.free()
		return ToolResult.fail("pack() failed (error %d)." % pack_error)
	var save_error: Error = ResourceSaver.save(packed, full_path)
	if is_instance_valid(root):
		root.free()
	if save_error != OK:
		return ToolResult.fail("ResourceSaver.save() failed (error %d) for %s." % [save_error, full_path])
	ToolBox.update_editor_filesystem(full_path)

	var created: Array = []
	for key in made.keys():
		created.append(str(key))
	return ToolResult.ok("Scene created: %s\n%s\n\nOpen it with `open_file` before editing." % [
		full_path,
		JSON.stringify({"root": str(root_name), "node_paths": created}, "\t"),
	])


## 建一个子节点（含初始属性）。返回错误文本，空表示成功。
func _build_child(p_root: Node, p_made: Dictionary, p_entry: Variant, p_index: int) -> String:
	if typeof(p_entry) != TYPE_DICTIONARY:
		return "nodes[%d] must be an object." % p_index
	var entry: Dictionary = p_entry
	var node_path: String = text_of(entry, "node_path")
	if node_path.is_empty():
		return "nodes[%d]: 'node_path' is required, e.g. \"Player/Body\"." % p_index
	var slash: int = node_path.rfind("/")
	var parent_key: String = "." if slash < 0 else node_path.substr(0, slash)
	var wanted: String = node_path if slash < 0 else node_path.substr(slash + 1)
	if not p_made.has(parent_key):
		return "nodes[%d]: parent '%s' is not created yet — list entries parent-first." % [p_index, parent_key]
	var parent: Node = p_made[parent_key]

	var node_type: String = text_of(entry, "node_type")
	var scene_path: String = text_of(entry, "scene_path")
	var node: Node = null
	if not scene_path.is_empty():
		var built: Dictionary = instantiate_by_scene(scene_path)
		if built.node == null:
			return "nodes[%d]: %s" % [p_index, str(built.error)]
		node = built.node
	elif not node_type.is_empty():
		node = instantiate_by_class(node_type)
		if node == null:
			return "nodes[%d]: '%s' is not an instantiable Node class.%s" % [p_index, node_type, candidate_suffix(class_candidates(node_type))]
	else:
		return "nodes[%d]: one of 'node_type' or 'scene_path' is required." % p_index

	node.name = wanted.validate_node_name()
	parent.add_child(node)
	if str(node.name) != wanted:
		return "nodes[%d]: '%s' already exists under '%s'." % [p_index, wanted, parent_key]
	node.owner = p_root
	p_made[node_path] = node

	var properties: Variant = entry.get("properties")
	if properties == null:
		return ""
	if not (properties is Dictionary):
		return "nodes[%d]: 'properties' must be an object." % p_index
	var prop_map: Dictionary = properties
	for raw_key in prop_map.keys():
		var prop: String = str(raw_key)
		var sub_path: Array = []
		if prop.contains(":"):
			var parts: PackedStringArray = prop.split(":")
			prop = parts[0].strip_edges()
			for index in range(1, parts.size()):
				var piece: String = parts[index].strip_edges()
				if not piece.is_empty():
					sub_path.append(piece)
		var write: Dictionary = resolve_property_write(node, prop, sub_path, prop_map[raw_key])
		if not bool(write.get("ok", false)):
			return "nodes[%d] (%s): %s" % [p_index, node_path, str(write.get("error", ""))]
		node.set_indexed(str(write.get("indexed")), write.get("value"))
	return ""
