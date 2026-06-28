@tool
extends AiTool

## 主Agent专用的节点属性获取工具。
##
## 通过直接加载场景文件（.tscn）并在内存中实例化，
## 获取指定节点的属性列表。不需要在编辑器中打开目标场景，
## 适用于快速查询任意场景文件的节点配置。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "get_node_properties"
	tool_description = "Gets the properties of a node from a scene file."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"scene_path": {
				"type": "string",
				"description": "The scene file path, e.g., 'res://xxx.tscn'"
			},
			"node_path": {
				"type": "string",
				"description": "Target node path. Use '.' for root node, 'NodeName' or 'Parent/Child' for sub-nodes. Default: '.'"
			}
		},
		"required": ["scene_path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var scene_path: String = p_args.get("scene_path", "")
	var node_path: String = p_args.get("node_path", ".")
	
	# --- 参数验证 ---
	if scene_path.is_empty():
		return ToolResult.fail("Error: 'scene_path' is required.")
	
	if not scene_path.begins_with("res://"):
		return ToolResult.fail("Error: 'scene_path' must start with 'res://'.")
	
	if not ResourceLoader.exists(scene_path):
		return ToolResult.fail("Error: Scene file not found: '%s'" % scene_path)
	
	# --- 在内存中加载并实例化场景 ---
	# instance 是孤立节点，不挂载到任何场景树，用完即 free()
	var packed_scene: PackedScene = load(scene_path)
	if not packed_scene:
		return ToolResult.fail("Error: Failed to load scene: '%s'" % scene_path)
	
	var instance: Node = packed_scene.instantiate()
	if not instance:
		return ToolResult.fail("Error: Failed to instantiate scene.")
	
	# --- 查找目标节点 ---
	var target: Node = _find_node(instance, node_path)
	if not target:
		var hint: String = _build_node_hint(instance, node_path)
		instance.free()
		return ToolResult.fail(hint)
	
	# --- 获取表层属性（不递归 Resource） ---
	var properties: Array[Dictionary] = _get_flat_properties(target)
	
	# --- 格式化为表格输出 ---
	var result: String = _format_output(scene_path, target, properties)
	
	# --- 清理 ---
	instance.free()
	
	return ToolResult.ok(result)


# --- Private Functions ---

# 根据路径查找节点，支持 '.' / 'NodeName' / 'Parent/Child'
func _find_node(p_root: Node, p_path: String) -> Node:
	if p_path.is_empty() or p_path == ".":
		return p_root
	
	# 尝试直接用 NodePath 查找
	var node: Node = p_root.get_node_or_null(p_path)
	if node:
		return node
	
	# 按名称递归模糊查找
	return _find_node_by_name(p_root, p_path)


func _find_node_by_name(p_node: Node, p_name: String) -> Node:
	if p_node.name == p_name:
		return p_node
	
	for child: Node in p_node.get_children():
		var found: Node = _find_node_by_name(child, p_name)
		if found:
			return found
	
	return null


# 生成节点未找到时的错误提示，列出所有可用路径
func _build_node_hint(p_root: Node, p_input_path: String) -> String:
	var all_paths: Array[String] = []
	_collect_node_paths(p_root, ".", all_paths)
	
	var hint: String = "❌ Node not found: '%s'\n\n" % p_input_path
	hint += "📋 Available node paths:\n"
	for path: String in all_paths:
		hint += "   • %s\n" % path
	
	hint += "\n💡 Tip: Use '.' for root node, 'NodeName' for direct child, 'Parent/Child' for sub-nodes."
	return hint


# 递归收集所有节点路径
func _collect_node_paths(p_node: Node, p_current_path: String, p_paths: Array[String]) -> void:
	if p_current_path != ".":
		p_paths.append(p_current_path)
	
	for child: Node in p_node.get_children():
		var child_path: String
		if p_current_path == ".":
			child_path = child.name
		else:
			child_path = p_current_path + "/" + child.name
		_collect_node_paths(child, child_path, p_paths)


# 获取节点的表层属性列表（不递归 Resource 内部）
func _get_flat_properties(p_node: Node) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var prop_list: Array[Dictionary] = p_node.get_property_list()
	
	for prop: Dictionary in prop_list:
		var usage: int = prop.get("usage", 0)
		
		# 只保留编辑器可见属性
		if not (usage & PROPERTY_USAGE_EDITOR):
			continue
		# 过滤组/类别/子组等非实际属性条目
		if usage & (PROPERTY_USAGE_GROUP | PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_SUBGROUP):
			continue
		
		var prop_name: String = prop.get("name", "")
		var prop_type: int = prop.get("type", TYPE_NIL)
		var prop_value: Variant = p_node.get(prop_name)
		
		result.append({
			"name": prop_name,
			"value": str(prop_value),
			"type": type_string(prop_type)
		})
	
	return result


# 将属性列表格式化为易读的 ASCII 表格
func _format_output(p_scene_path: String, p_node: Node, p_properties: Array[Dictionary]) -> String:
	var lines: PackedStringArray = []
	
	# 头部信息
	lines.append("**📦 Scene:** %s" % p_scene_path)
	lines.append("**🎯 Node:** %s (%s)" % [p_node.name, p_node.get_class()])
	lines.append("")
	
	# Markdown 表格
	lines.append("| Property | Value | Type |")
	lines.append("|---------|-------|------|")
	
	for prop: Dictionary in p_properties:
		var name: String = prop["name"]
		var value: String = prop["value"]
		var type_name: String = prop["type"]
		# 值中含 '|' 时转义，避免破坏表格
		value = value.replace("|", "\\|")
		lines.append("| %s | %s | %s |" % [name, value, type_name])
	
	return "\n".join(lines)
