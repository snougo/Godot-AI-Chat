@tool
extends BaseSceneTool

## 安全创建 `.tscn` 场景文件。

# --- Enums / Constants ---

## 允许的扩展名白名单
const ALLOWED_EXTENSIONS: Array[String] = ["tscn"]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_new_scene"
	tool_description = "Safely create a `.tscn` scene file. NEXT STEP: Use 'open_scene' to edit it."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"scene_path": { 
				"type": "string", 
				"description": "The full path where the scene file should be saved." 
			},
			"tree_structure": {
				"type": "string",
				"description": "Markdown-Header style tree. Use '#' count for hierarchy depth.\nFormat: # NodeName (ClassName_OR_Path) {json}\nExample:\n# Main (Node3D)\n## Player (res://player.tscn) {\"position\": [10, 0, 0]}\n### Camera (Camera3D)\n## Floor (StaticBody3D)"
			}
		},
		"required": ["scene_path", "tree_structure"]
	}


## 执行创建场景操作
## [param p_args]: 包含 scene_path 和 tree_structure 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var new_scene_path: String = p_args.get("scene_path", "")
	var tree_text: String = p_args.get("tree_structure", "")
	
	var validation_result: Dictionary = _validate_scene_path(new_scene_path)
	if not validation_result.get("success", false):
		return validation_result
	
	if FileAccess.file_exists(new_scene_path):
		return {"success": false, "data": "File already exists: %s" % new_scene_path}
	
	var parse_result: Dictionary = _parse_tree_structure(tree_text)
	if not parse_result.get("success", false):
		return parse_result
	
	var root_node: Node = parse_result.root_node
	
	if not root_node:
		return {"success": false, "data": "Empty tree."}
	
	return _save_scene(root_node, new_scene_path)


# --- Private Functions ---

## 验证场景路径
## [param p_path]: 场景路径
## [return]: 验证结果字典
func _validate_scene_path(p_path: String) -> Dictionary:
	var security_error: String = validate_path_safety(p_path)
	if not security_error.is_empty():
		return {"success": false, "data": security_error}
	
	var extension: String = p_path.get_extension().to_lower()
	if extension not in ALLOWED_EXTENSIONS:
		return {"success": false, "data": "Invalid scene_path extension. Allowed: %s" % ", ".join(ALLOWED_EXTENSIONS)}
	
	return {"success": true}


## 解析树结构
## [param p_tree_text]: 树结构文本
## [return]: 包含 root_node 的结果字典
func _parse_tree_structure(p_tree_text: String) -> Dictionary:
	var root_node: Node = null
	var node_stack: Array = []
	var lines: PackedStringArray = p_tree_text.split("\n")
	var regex := RegEx.new()
	regex.compile("^([^\\(]+)\\s*\\((.+)\\)\\s*(?:(\\{.*\\}))?$")
	
	for line in lines:
		var stripped_line: String = line.strip_edges()
		if stripped_line.is_empty():
			continue
		
		var level: int = _count_header_level(stripped_line)
		if level == 0:
			continue
		
		var content: String = stripped_line.substr(level).strip_edges()
		var match_result: RegExMatch = regex.search(content)
		
		if not match_result:
			_cleanup_nodes(root_node)
			return {"success": false, "data": "Parse error: '%s'" % line}
		
		var node_result: Dictionary = _create_node_from_match(match_result)
		if not node_result.get("success", false):
			_cleanup_nodes(root_node)
			return node_result
		
		var new_node: Node = node_result.node
		var stack_result: Dictionary = _update_node_stack(node_stack, new_node, level, root_node)
		
		if not stack_result.get("success", false):
			_cleanup_nodes(root_node)
			return stack_result
		
		root_node = stack_result.root_node
	
	return {"success": true, "root_node": root_node}


## 计算标题级别
## [param p_line]: 行文本
## [return]: 标题级别
func _count_header_level(p_line: String) -> int:
	var level: int = 0
	for char_code in p_line:
		if char_code == "#":
			level += 1
		else:
			break
	return level


## 从匹配结果创建节点
## [param p_match]: 正则匹配结果
## [return]: 包含节点和成功状态的字典
func _create_node_from_match(p_match: RegExMatch) -> Dictionary:
	var node_name: String = p_match.get_string(1).strip_edges()
	var type_str: String = p_match.get_string(2).strip_edges()
	var json_props_str: String = p_match.get_string(3).strip_edges()
	
	var new_node: Node = _instantiate_node_by_type(type_str)
	if not new_node:
		return {"success": false, "data": "Invalid Class/Path: '%s'" % type_str}
	
	new_node.name = node_name
	
	if not json_props_str.is_empty():
		var json := JSON.new()
		if json.parse(json_props_str) == OK and json.data is Dictionary:
			apply_properties(new_node, json.data)
	
	return {"success": true, "node": new_node}


## 根据类型字符串实例化节点
## [param p_type_str]: 类型字符串
## [return]: 实例化的节点
func _instantiate_node_by_type(p_type_str: String) -> Node:
	if p_type_str.begins_with("res://"):
		if ResourceLoader.exists(p_type_str):
			var scn := ResourceLoader.load(p_type_str, "", ResourceLoader.CACHE_MODE_IGNORE)
			if scn is PackedScene:
				return scn.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
	elif ClassDB.class_exists(p_type_str):
		return ClassDB.instantiate(p_type_str)
	return null


## 更新节点栈
## [param p_node_stack]: 节点栈
## [param p_new_node]: 新节点
## [param p_level]: 层级
## [param p_root_node]: 根节点
## [return]: 包含成功状态和根节点的字典
func _update_node_stack(p_node_stack: Array, p_new_node: Node, p_level: int, p_root_node: Node) -> Dictionary:
	if p_node_stack.is_empty():
		p_node_stack.append({"node": p_new_node, "level": p_level})
		return {"success": true, "root_node": p_new_node}
	
	while not p_node_stack.is_empty() and p_node_stack.back()["level"] >= p_level:
		p_node_stack.pop_back()
	
	if p_node_stack.is_empty():
		p_new_node.free()
		return {"success": false, "data": "Hierarchy error at %s" % p_new_node.name}
	
	p_node_stack.back()["node"].add_child(p_new_node)
	p_node_stack.append({"node": p_new_node, "level": p_level})
	
	return {"success": true, "root_node": p_root_node}


## 保存场景
## [param p_root_node]: 根节点
## [param p_scene_path]: 场景路径
## [return]: 操作结果字典
func _save_scene(p_root_node: Node, p_scene_path: String) -> Dictionary:
	set_owner_recursive(p_root_node, p_root_node)
	
	var packed_scene := PackedScene.new()
	packed_scene.pack(p_root_node)
	
	var base_dir: String = p_scene_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(base_dir):
		if is_instance_valid(p_root_node):
			p_root_node.free()
		return {"success": false, "data": "Directory not found: %s. Please use 'create_folder' tool first." % base_dir}
	
	var err: Error = ResourceSaver.save(packed_scene, p_scene_path)
	
	if is_instance_valid(p_root_node):
		p_root_node.free()
	
	if err == OK:
		ToolBox.update_editor_filesystem(p_scene_path)
		return {"success": true, "data": "Scene created at %s" % p_scene_path}
	else:
		return {"success": false, "data": "Save Failed: %d" % err}


## 清理节点
## [param p_node]: 要清理的节点
func _cleanup_nodes(p_node: Node) -> void:
	if p_node and is_instance_valid(p_node):
		p_node.free()
