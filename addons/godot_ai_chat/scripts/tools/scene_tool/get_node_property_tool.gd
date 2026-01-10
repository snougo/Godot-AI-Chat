@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "get_current_scene_node_property"
	tool_description = "Retrieves the class, children, and editable properties of a node in the currently active scene (or a specified .tscn file). Returns values formatted for easy re-use with 'set_node_property'."


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


func execute(args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var scene_path: String = args.get("scene_path", "")
	var node_path: String = args.get("node_path", ".")
	
	var root: Node = null
	var is_instantiated: bool = false
	
	# 1. 确定 Root Node
	if not scene_path.is_empty():
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
				"type": _get_type_name(p.type),
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
			return val.to_html() # Returns hex string like "rrggbbaa"
		TYPE_OBJECT:
			if val == null:
				return null
			if val is Resource:
				if not val.resource_path.is_empty():
					return val.resource_path # Return path for easy re-loading
				else:
					return "<Built-in Resource: %s>" % val.get_class()
			return "<Object: %s>" % val.get_class()
		_:
			return val # Return basic types (int, float, bool, string, array, dict) as is


func _get_type_name(type_int: int) -> String:
	match type_int:
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR2I: return "Vector2i"
		TYPE_RECT2: return "Rect2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_VECTOR3I: return "Vector3i"
		TYPE_COLOR: return "Color"
		TYPE_OBJECT: return "Resource/Object"
		TYPE_ARRAY: return "Array"
		TYPE_DICTIONARY: return "Dictionary"
		_: return "Variant"
