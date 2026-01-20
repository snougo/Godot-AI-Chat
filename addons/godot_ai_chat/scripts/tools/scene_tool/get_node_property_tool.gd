@tool
extends BaseSceneTool

func _init() -> void:
	tool_name = "get_node_property"
	tool_description = "Reads node properties. REQUIRES 'node_path' from 'get_current_active_scene'."

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": { 
				"type": "string", 
				"description": "Path to the node relative to the scene root. Use '.' for the root itself."
			},
			"scene_path": {
				"type": "string",
				"description": "Optional. The 'res://' path to a .tscn file. If provided, the tool inspects this file instead of the active editor scene."
			}
		},
		"required": ["node_path"]
	}

func execute(args: Dictionary) -> Dictionary:
	var scene_path: String = args.get("scene_path", "")
	var node_path: String = args.get("node_path", ".")
	
	var root: Node = null
	var is_instantiated: bool = false
	
	# 1. 确定 Root Node
	if not scene_path.is_empty():
		# 新增：安全检查
		var security_error = validate_path_safety(scene_path)
		if not security_error.is_empty():
			return {"success": false, "data": security_error}

		if not FileAccess.file_exists(scene_path):
			return {"success": false, "data": "Error: Scene file not found at " + scene_path}
		
		var packed_scene = load(scene_path)
		if not packed_scene or not (packed_scene is PackedScene):
			return {"success": false, "data": "Error: Failed to load PackedScene from " + scene_path}
		root = packed_scene.instantiate()
		is_instantiated = true
	else:
		if not Engine.is_editor_hint():
			return {"success": false, "data": "Error: Editor only tool."}
		root = EditorInterface.get_edited_scene_root()
		if not root:
			return {"success": false, "data": "Error: No active scene in editor."}
	
	# 2. 查找目标 Node
	var node = root if node_path == "." else root.get_node_or_null(node_path)
	if not node:
		if is_instantiated: root.queue_free()
		return {"success": false, "data": "Error: Node not found: %s" % node_path}
	
	# 3. 收集信息
	var info = {
		"name": node.name,
		"class": node.get_class(),
		"path": root.get_path_to(node) if root != node else ".",
		"children": [],
		"properties": {}
	}
	
	for child in node.get_children():
		info["children"].append("%s (%s)" % [child.name, child.get_class()])
	
	var prop_list = node.get_property_list()
	for p in prop_list:
		if p.usage & PROPERTY_USAGE_EDITOR:
			var raw_val = node.get(p.name)
			info["properties"][p.name] = {
				"type": get_type_name(p.type),
				"value": _serialize_value(raw_val)
			}
	
	if is_instantiated:
		root.queue_free()
	
	return {"success": true, "data": info}

func _serialize_value(val: Variant) -> Variant:
	match typeof(val):
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return [val.x, val.y]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return [val.x, val.y, val.z]
		TYPE_VECTOR4, TYPE_VECTOR4I:
			return [val.x, val.y, val.z, val.w]
		TYPE_RECT2, TYPE_RECT2I:
			return [val.position.x, val.position.y, val.size.x, val.size.y]
		TYPE_COLOR:
			return val.to_html() 
		TYPE_OBJECT:
			if val == null:
				return null
			if val is Resource:
				if not val.resource_path.is_empty():
					return val.resource_path
				else:
					return "<Built-in Resource: %s>" % val.get_class()
			return "<Object: %s>" % val.get_class()
		_:
			return val
