@tool
extends BaseSceneTool


func _init() -> void:
	tool_name = "add_new_node"
	tool_description = "Add a new node to the active scene. REQUIRES 'parent_path' from 'get_current_active_scene'."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"parent_path": { "type": "string", "description": "Path to the parent node. Use '.' for root." },
			"node_name": { "type": "string", "description": "Name for the new node." },
			"node_type": { "type": "string", "description": "Godot ClassName (e.g. 'Node3D') OR a 'res://' path to a .tscn file." },
			"properties": { 
				"type": "object", 
				"description": "Optional dictionary of properties to set (e.g. {'position': [10, 0, 0], 'visible': false})." 
			}
		},
		"required": ["parent_path", "node_name", "node_type"]
	}


func execute(args: Dictionary, _context_provider: Object) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Editor only."}
	
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return {"success": false, "data": "No active scene."}
	
	var parent_path = args.get("parent_path", ".")
	var parent = root if parent_path == "." else root.get_node_or_null(parent_path)
	
	if not parent:
		return {"success": false, "data": "Parent node not found: %s" % parent_path}
	
	var node_name = args.get("node_name", "NewNode")
	if parent.has_node(node_name):
		return {"success": false, "data": "Name collision: Node '%s' already exists under parent." % node_name}
	
	var type_str = args.get("node_type", "")
	var new_node: Node = null
	
	# 实例化逻辑
	if type_str.begins_with("res://"):
		if ResourceLoader.exists(type_str):
			var res = ResourceLoader.load(type_str)
			if res is PackedScene:
				new_node = res.instantiate()
			else:
				return {"success": false, "data": "Resource is not a PackedScene: %s" % type_str}
		else:
			return {"success": false, "data": "File not found: %s" % type_str}
	elif ClassDB.class_exists(type_str):
		new_node = ClassDB.instantiate(type_str)
	else:
		return {"success": false, "data": "Invalid node type or class: %s" % type_str}
	
	# 添加到场景树
	if new_node:
		new_node.name = node_name
		parent.add_child(new_node)
		new_node.owner = root # 确保保存
		
		# 应用属性
		var properties = args.get("properties", {})
		if properties is Dictionary and not properties.is_empty():
			apply_properties(new_node, properties)
		
		# 标记未保存
		var undo_redo = EditorInterface.get_editor_undo_redo()
		undo_redo.create_action("AI Add Node")
		undo_redo.add_do_property(root, "name", root.name)
		undo_redo.add_undo_property(root, "name", root.name)
		undo_redo.commit_action()
		
		return {"success": true, "data": "Node '%s' added successfully." % new_node.name}
	
	return {"success": false, "data": "Unknown error creating node."}
