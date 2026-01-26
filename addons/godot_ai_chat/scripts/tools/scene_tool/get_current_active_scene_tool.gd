@tool
extends BaseSceneTool

## 获取当前活动场景的场景树。
## 首先执行以获取 add/get/set 节点工具所需的 'node_path'。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "get_current_active_scene"
	tool_description = "Retrieves the scene tree."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


## 执行获取当前活动场景操作
## [param p_args]: 参数字典（此工具不需要参数）
## [return]: 包含场景树结构的字典
func execute(p_args: Dictionary) -> Dictionary:
	var edited_root := EditorInterface.get_edited_scene_root()
	if not edited_root:
		return {"success": false, "data": "No active Scene found in Editor Tab."}
	
	var file_path: String = edited_root.scene_file_path
	var file_name: String = file_path.get_file()
	
	if file_name.is_empty():
		file_name = "%s (Unsaved)" % edited_root.name
	
	var structure: String = _get_scene_tree_string(edited_root)
	var display_text: String = "Current Scene: **%s**\n\n```scene_tree\n%s\n```" % [file_name, structure]
	
	return {"success": true, "data": display_text}


# --- Private Functions ---

## 获取场景树字符串表示
## [param p_root]: 根节点
## [return]: 场景树字符串
func _get_scene_tree_string(p_root: Node) -> String:
	var lines: PackedStringArray = []
	_traverse_node(p_root, p_root, 0, lines)
	return "\n".join(lines)


## 递归遍历节点
## [param p_node]: 当前节点
## [param p_root]: 根节点
## [param p_depth]: 深度
## [param p_lines]: 输出行数组
func _traverse_node(p_node: Node, p_root: Node, p_depth: int, p_lines: PackedStringArray) -> void:
	if p_node != p_root and p_node.owner != p_root:
		return
	
	var indent: String = "  ".repeat(p_depth)
	var type: String = p_node.get_class()
	var extra_info: String = ""
	
	if p_node != p_root and not p_node.scene_file_path.is_empty():
		extra_info = " [Instance: %s]" % p_node.scene_file_path
	
	p_lines.append("%s- %s (%s)%s" % [indent, p_node.name, type, extra_info])
	
	for child in p_node.get_children():
		_traverse_node(child, p_root, p_depth + 1, p_lines)
