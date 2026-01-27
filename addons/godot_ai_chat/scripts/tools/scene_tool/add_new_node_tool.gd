@tool
extends BaseSceneTool

## 向活动场景添加新节点。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "add_new_node"
	tool_description = "Add a new node to the active scene. Using 'get_current_active_scene' before adding."

# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"parent_path": { 
				"type": "string", 
				"description": "Path to the parent node. Use '.' for root." 
			},
			"node_name": { 
				"type": "string", 
				"description": "Name for the new node." 
			},
			"node_type": { 
				"type": "string", 
				"description": "Godot ClassName (e.g. 'Node3D') OR a 'res://' path to a .tscn file." 
			},
			"properties": { 
				"type": "object", 
				"description": "Optional dictionary of properties to set (e.g. {'position': [10, 0, 0], 'visible': false})." 
			}
		},
		"required": ["parent_path", "node_name", "node_type"]
	}


## 执行添加节点操作
## [param p_args]: 包含 parent_path、node_name、node_type 和 properties 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Editor only."}
	
	var root := EditorInterface.get_edited_scene_root()
	if not root:
		return {"success": false, "data": "No active scene."}
	
	var parent_path: String = p_args.get("parent_path", ".")
	var parent: Node = root if parent_path == "." else root.get_node_or_null(parent_path)
	
	if not parent:
		return {"success": false, "data": "Parent node not found: %s" % parent_path}
	
	var node_name: String = p_args.get("node_name", "NewNode")
	if parent.has_node(node_name):
		return {"success": false, "data": "Name collision: Node '%s' already exists under parent." % node_name}
	
	var type_str: String = p_args.get("node_type", "")
	var new_node: Node = _instantiate_node(type_str)
	
	if new_node == null:
		return {"success": false, "data": "Invalid node type or class: %s" % type_str}
	
	_add_node_to_scene(new_node, node_name, parent, root)
	
	var properties: Dictionary = p_args.get("properties", {})
	if properties is Dictionary and not properties.is_empty():
		apply_properties(new_node, properties)
	
	_create_undo_action(root)
	
	return {"success": true, "data": "Node '%s' added successfully." % new_node.name}


# --- Private Functions ---

## 实例化节点
## [param p_type_str]: 类型字符串（类名或场景路径）
## [return]: 实例化的节点，失败返回 null
func _instantiate_node(p_type_str: String) -> Node:
	if p_type_str.begins_with("res://"):
		if ResourceLoader.exists(p_type_str):
			var res = ResourceLoader.load(p_type_str)
			if res is PackedScene:
				# 显式转换为 Node 类型，避免类型不匹配错误
				var instantiated_node: Node = res.instantiate()
				return instantiated_node
			else:
				return null
		else:
			return null
	elif ClassDB.class_exists(p_type_str):
		return ClassDB.instantiate(p_type_str)
	return null


## 将节点添加到场景
## [param p_node]: 要添加的节点
## [param p_name]: 节点名称
## [param p_parent]: 父节点
## [param p_root]: 场景根节点
func _add_node_to_scene(p_node: Node, p_name: String, p_parent: Node, p_root: Node) -> void:
	p_node.name = p_name
	p_parent.add_child(p_node)
	p_node.owner = p_root


## 创建撤销操作
## [param p_root]: 场景根节点
func _create_undo_action(p_root: Node) -> void:
	var undo_redo := EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("AI Add Node")
	undo_redo.add_do_property(p_root, "name", p_root.name)
	undo_redo.add_undo_property(p_root, "name", p_root.name)
	undo_redo.commit_action()
