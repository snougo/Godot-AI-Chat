@tool
extends BaseSceneTool

## 读取节点属性。
## 需要从 'get_current_active_scene' 获取 'node_path'。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "get_node_property"
	tool_description = "Reads node properties. Using 'get_current_active_scene' before reading."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
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


## 执行获取节点属性操作
## [param p_args]: 包含 node_path 和可选 scene_path 的参数字典
## [return]: 包含节点信息的字典
func execute(p_args: Dictionary) -> Dictionary:
	var scene_path: String = p_args.get("scene_path", "")
	var node_path: String = p_args.get("node_path", ".")
	
	var root_result: Dictionary = _get_root_node(scene_path)
	if not root_result.get("success", false):
		return root_result
	
	var root: Node = root_result.root
	var is_instantiated: bool = root_result.is_instantiated
	
	var node: Node = root if node_path == "." else root.get_node_or_null(node_path)
	if not node:
		if is_instantiated:
			root.queue_free()
		return {"success": false, "data": "Error: Node not found: %s" % node_path}
	
	var info: Dictionary = _collect_node_info(root, node)
	
	if is_instantiated:
		root.queue_free()
	
	return {"success": true, "data": info}


# --- Private Functions ---

## 获取根节点
## [param p_scene_path]: 场景路径（可选）
## [return]: 包含 root 和 is_instantiated 的字典
func _get_root_node(p_scene_path: String) -> Dictionary:
	if not p_scene_path.is_empty():
		var security_error: String = validate_path_safety(p_scene_path)
		if not security_error.is_empty():
			return {"success": false, "data": security_error}
		
		if not FileAccess.file_exists(p_scene_path):
			return {"success": false, "data": "Error: Scene file not found at " + p_scene_path}
		
		var packed_scene = load(p_scene_path)
		if not packed_scene or not (packed_scene is PackedScene):
			return {"success": false, "data": "Error: Failed to load PackedScene from " + p_scene_path}
		
		return {"success": true, "root": packed_scene.instantiate(), "is_instantiated": true}
	else:
		if not Engine.is_editor_hint():
			return {"success": false, "data": "Error: Editor only tool."}
		
		var root := EditorInterface.get_edited_scene_root()
		if not root:
			return {"success": false, "data": "Error: No active scene in editor."}
		
		return {"success": true, "root": root, "is_instantiated": false}


## 收集节点信息
## [param p_root]: 根节点
## [param p_node]: 目标节点
## [return]: 节点信息字典
func _collect_node_info(p_root: Node, p_node: Node) -> Dictionary:
	var info: Dictionary = {
		"name": p_node.name,
		"class": p_node.get_class(),
		"path": p_root.get_path_to(p_node) if p_root != p_node else ".",
		"children": [],
		"properties": {}
	}
	
	for child in p_node.get_children():
		info["children"].append("%s (%s)" % [child.name, child.get_class()])
	
	var prop_list: Array[Dictionary] = p_node.get_property_list()
	for p in prop_list:
		if p.usage & PROPERTY_USAGE_EDITOR:
			var raw_val: Variant = p_node.get(p.name)
			info["properties"][p.name] = {
				"type": get_type_name(p.type),
				"value": _serialize_value(raw_val)
			}
	
	return info


## 序列化值
## [param p_val]: 要序列化的值
## [return]: 序列化后的值
func _serialize_value(p_val: Variant) -> Variant:
	match typeof(p_val):
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return [p_val.x, p_val.y]
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return [p_val.x, p_val.y, p_val.z]
		TYPE_VECTOR4, TYPE_VECTOR4I:
			return [p_val.x, p_val.y, p_val.z, p_val.w]
		TYPE_RECT2, TYPE_RECT2I:
			return [p_val.position.x, p_val.position.y, p_val.size.x, p_val.size.y]
		TYPE_COLOR:
			return p_val.to_html()
		TYPE_OBJECT:
			return _serialize_object(p_val)
		_:
			return p_val


## 序列化对象
## [param p_val]: 对象值
## [return]: 序列化后的对象
func _serialize_object(p_val: Variant) -> Variant:
	if p_val == null:
		return null
	if p_val is Resource:
		if not p_val.resource_path.is_empty():
			return p_val.resource_path
		else:
			return "<Built-in Resource: %s>" % p_val.get_class()
	return "<Object: %s>" % p_val.get_class()
