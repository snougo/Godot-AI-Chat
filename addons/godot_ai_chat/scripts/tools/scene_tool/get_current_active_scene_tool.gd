@tool
extends AiTool


func _init() -> void:
	tool_name = "get_current_active_scene"
	tool_description = "Get the file name and scene tree structure of the currently active opening scene in Scene Editor."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(_args: Dictionary, _context_provider: ContextProvider) -> Dictionary:
	var edited_root := EditorInterface.get_edited_scene_root()
	if edited_root:
		var file_path: String = edited_root.scene_file_path
		var file_name: String = file_path.get_file()
		
		# 处理新建且从未保存过的场景
		if file_name.is_empty():
			file_name = "%s (Unsaved)" % edited_root.name
		
		var structure: String = _get_scene_tree_string(edited_root)
		
		# 优化点：直接返回格式化好的 Markdown 字符串
		# 这样 AI 收到结果后直接展示，就能触发前端的 scene_tree 代码块渲染
		var display_text: String = "Current Scene: **%s**\n\n```scene_tree\n%s\n```" % [file_name, structure]
		
		return {
			"success": true, 
			"data": display_text
		}
	
	return {"success": false, "data": "No active Scene found in Editor Tab."}


func _get_scene_tree_string(root: Node) -> String:
	var lines: PackedStringArray = []
	_traverse_node(root, root, 0, lines)
	return "\n".join(lines)


func _traverse_node(node: Node, root: Node, depth: int, lines: PackedStringArray) -> void:
	# 仅展示属于当前编辑场景的节点（owner为root的节点），或者是root本身
	if node != root and node.owner != root:
		return
	
	var indent: String = "  ".repeat(depth)
	var type: String = node.get_class()
	var extra_info: String = ""
	
	# 如果是实例化的子场景，添加标记
	if node != root and not node.scene_file_path.is_empty():
		extra_info = " [Instance: %s]" % node.scene_file_path
	
	lines.append("%s- %s (%s)%s" % [indent, node.name, type, extra_info])
	
	for child in node.get_children():
		_traverse_node(child, root, depth + 1, lines)
