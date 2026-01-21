@tool
class_name AttachmentProcessor
extends RefCounted

## 负责处理用户输入中的附件（图片、场景文件等）

static func process_input(raw_text: String) -> Dictionary:
	var result = {
		"final_text": raw_text,
		"image_data": PackedByteArray(),
		"image_mime": ""
	}
	
	var lines = raw_text.split("\n")
	var processed_lines: Array[String] = []
	var image_found := false
	
	for line in lines:
		var trimmed = line.strip_edges()
		if trimmed.begins_with("res://"):
			var ext = trimmed.get_extension().to_lower()
			
			# 1. 处理图片 (仅处理找到的第一张图片)
			if not image_found and ext in ["png", "jpg", "jpeg", "webp"]:
				var img_info = _load_image(trimmed)
				if not img_info.is_empty():
					result.image_data = img_info.data
					result.image_mime = img_info.mime
					image_found = true
					# 图片路径行不保留在文本中，因为已经进了 image_data 字段
					continue
			
			# 2. 处理场景文件
			elif ext == "tscn":
				var scene_md = _parse_scene_to_markdown(trimmed)
				processed_lines.append(scene_md)
				continue
		
		processed_lines.append(line)
	
	result.final_text = "\n".join(processed_lines)
	return result


# --- 内部辅助 ---

static func _load_image(path: String) -> Dictionary:
	if not FileAccess.file_exists(path): return {}
	var file = FileAccess.open(path, FileAccess.READ)
	if not file: return {}
	
	var buffer = file.get_buffer(file.get_length())
	var mime = "image/png"
	if path.ends_with(".jpg") or path.ends_with(".jpeg"): mime = "image/jpeg"
	elif path.ends_with(".webp"): mime = "image/webp"
	
	return {"data": buffer, "mime": mime}


static func _parse_scene_to_markdown(path: String) -> String:
	if not FileAccess.file_exists(path): return path
	var scene: PackedScene = load(path)
	if not scene: return path
	
	var state: SceneState = scene.get_state()
	var md = "Context for Scene: `%s`\n```\nScene Tree Structure:\n" % path.get_file()
	
	var node_count = state.get_node_count()
	# 使用字典存储 {NodePath: node_index}，方便查找父节点
	var path_to_index = {}
	# 存储 {parent_index: [child_indices]}
	var parent_map = {} 
	
	for i in range(node_count):
		var current_path: NodePath = state.get_node_path(i)
		path_to_index[current_path] = i
		
		if i == 0:
			# 根节点，跳过父节点查找
			continue
			
		# 寻找父节点路径
		# 在 SceneState 中，get_node_path 返回的是相对于根的相对路径
		# 例如: "MarginContainer/VBoxContainer"
		# 它的父路径应该是 "MarginContainer"
		
		# 特殊处理：如果路径只有一级（直接挂在根节点下），父节点就是根节点（索引0）
		# 根节点的 NodePath 通常是 "."
		
		var parent_path: NodePath
		var name_count = current_path.get_name_count()
		
		if name_count <= 1:
			# 父节点是根节点，其路径在 SceneState 中表示为 "."
			parent_path = NodePath(".")
		else:
			# 移除最后一个名字，得到父路径
			# 例如 "A/B/C" -> "A/B"
			var names = []
			for k in range(name_count - 1):
				names.append(current_path.get_name(k))
			parent_path = NodePath("/".join(names))
		
		# 查找父节点索引
		if path_to_index.has(parent_path):
			var p_idx = path_to_index[parent_path]
			if not parent_map.has(p_idx): parent_map[p_idx] = []
			parent_map[p_idx].append(i)
		else:
			# 理论上不应该发生，除非场景文件损坏或逻辑漏洞
			# 兜底：挂在根节点下
			if not parent_map.has(0): parent_map[0] = []
			parent_map[0].append(i)
			
	md += _build_tree_string(state, 0, "", true, parent_map)
	md += "```"
	return md


static func _build_tree_string(state: SceneState, idx: int, prefix: String, is_last: bool, parent_map: Dictionary) -> String:
	var node_name = state.get_node_name(idx)
	var type = state.get_node_type(idx)
	
	# 获取脚本路径
	var script_path = ""
	for i in range(state.get_node_property_count(idx)):
		if state.get_node_property_name(idx, i) == "script":
			var script_res = state.get_node_property_value(idx, i)
			if script_res is Resource:
				script_path = script_res.resource_path
			break
	
	var line = prefix + ( "└─ " if is_last else "├─ " ) if idx != 0 else ""
	line += "%s (%s)" % [node_name, type]
	if not script_path.is_empty():
		line += " [script: `%s`]" % script_path
	line += "\n"
	
	var children = parent_map.get(idx, [])
	var new_prefix = prefix + ( "   " if is_last else "│  " ) if idx != 0 else ""
	
	for i in range(children.size()):
		line += _build_tree_string(state, children[i], new_prefix, i == children.size() - 1, parent_map)
	
	return line
