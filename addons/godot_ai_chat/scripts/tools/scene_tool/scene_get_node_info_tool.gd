@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "scene_get_node_info"
	tool_description = "Inspect a node's details. Returns its class, children, and a list of editable properties with current values. Use this before setting properties to verify names and types."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": { 
				"type": "string", 
				"description": "Path to the node relative to the current scene root. Use '.' for the root itself."
			}
		},
		"required": ["node_path"]
	}


func execute(args: Dictionary, _context_provider: Object) -> Dictionary:
	if not Engine.is_editor_hint(): return {"success": false, "data": "Editor only."}
	
	var root = EditorInterface.get_edited_scene_root()
	if not root: return {"success": false, "data": "No active scene."}
	
	var path = args.get("node_path", ".")
	var node = root if path == "." else root.get_node_or_null(path)
	
	if not node:
		return {"success": false, "data": "Node not found: %s" % path}
	
	var info = {
		"name": node.name,
		"class": node.get_class(),
		"path": root.get_path_to(node),
		"children": [],
		"properties": {}
	}
	
	# 列出子节点
	for child in node.get_children():
		info["children"].append("%s (%s)" % [child.name, child.get_class()])
	
	# 列出属性 (过滤掉大量无用的元数据)
	var prop_list = node.get_property_list()
	for p in prop_list:
		# 只显示通常可编辑的属性 (Usage STORAGE or EDITOR)
		if p.usage & PROPERTY_USAGE_EDITOR:
			var val = node.get(p.name)
			# 将 Object 转为易读字符串
			if typeof(val) == TYPE_OBJECT and val != null:
				if val is Resource:
					val = "<Resource: %s>" % val.resource_path if not val.resource_path.is_empty() else "<Built-in Resource: %s>" % val.get_class()
				else:
					val = "<Object: %s>" % val.get_class()
			
			info["properties"][p.name] = {
				"type": _get_type_name(p.type),
				"value": val
			}
	
	return {"success": true, "data": info}


func _get_type_name(type_int: int) -> String:
	# 简单类型映射，辅助模型理解
	match type_int:
		TYPE_BOOL: return "bool"
		TYPE_INT: return "int"
		TYPE_FLOAT: return "float"
		TYPE_STRING: return "String"
		TYPE_VECTOR2: return "Vector2"
		TYPE_VECTOR3: return "Vector3"
		TYPE_COLOR: return "Color"
		TYPE_OBJECT: return "Resource/Object"
		TYPE_ARRAY: return "Array"
		TYPE_DICTIONARY: return "Dictionary"
		_: return "Variant"
