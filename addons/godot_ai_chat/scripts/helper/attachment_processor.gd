class_name AttachmentProcessor
extends RefCounted

## 附件处理器
##
## 负责解析和处理用户输入中的特殊附件（如图片路径、场景文件等）。


# --- Public Functions ---

## 处理输入文本，提取附件
## [return]: 包含 final_text, images(Array[Dictionary]) 的字典
static func process_input(p_raw_text: String) -> Dictionary:
	var result: Dictionary = {
		"final_text": p_raw_text,
		"images": [] # [{"data": ..., "mime": ...}]
	}
	
	var lines: PackedStringArray = p_raw_text.split("\n")
	var processed_lines: Array[String] = []
	
	for line in lines:
		var trimmed: String = line.strip_edges()
		if trimmed.begins_with("res://"):
			var ext: String = trimmed.get_extension().to_lower()
			
			# 1. 处理图片 (支持多张)
			if ext in ["png", "jpg", "jpeg"]:
				var img_info: Dictionary = _load_image(trimmed)
				if not img_info.is_empty():
					result.images.append(img_info)
					continue # 路径已提取，不保留在文本
			
			# 2. 处理场景文件（.tscn / .scn）
			elif ext in ["tscn", "scn"]:
				var scene_md: String = _parse_scene_to_markdown(trimmed)
				processed_lines.append(scene_md)
				continue
			
			# 3. 处理脚本文件
			#elif ext == "gd":
				#var script_content: String = _read_script_content(trimmed)
				#processed_lines.append(script_content)
				#continue
			
			# 4. 处理着色器文件
			#elif ext == "gdshader":
				#var shader_content: String = _read_shader_content(trimmed)
				#processed_lines.append(shader_content)
				#continue
			
			# 5. 处理资源文件（.tres 读取原始文本，.res 读取属性摘要）
			#elif ext in ["tres", "res"]:
				#var resource_content: String = _read_resource_content(trimmed)
				#processed_lines.append(resource_content)
				#continue
		
		processed_lines.append(line)
	
	result.final_text = "\n".join(processed_lines)
	return result


# --- Private Functions ---

# 加载图片文件
static func _load_image(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {}
	
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not file:
		return {}
	
	var buffer: PackedByteArray = file.get_buffer(file.get_length())
	var mime: String = "image/png"
	if p_path.ends_with(".jpg") or p_path.ends_with(".jpeg"):
		mime = "image/jpeg"
	elif p_path.ends_with(".webp"):
		mime = "image/webp"
	
	return {"data": buffer, "mime": mime}


# 解析场景文件为 Markdown 格式
static func _parse_scene_to_markdown(p_path: String) -> String:
	if not FileAccess.file_exists(p_path):
		return p_path
	
	var scene: PackedScene = load(p_path)
	if not scene:
		return p_path
	
	var state: SceneState = scene.get_state()
	var md: String = "Context for Scene: `%s`\n```\nScene Tree Structure:\n" % p_path.get_file()
	
	var node_count: int = state.get_node_count()
	# 使用字典存储 {NodePath: node_index}，方便查找父节点
	var path_to_index: Dictionary = {}
	# 存储 {parent_index: [child_indices]}
	var parent_map: Dictionary = {} 
	
	for i in range(node_count):
		var current_path: NodePath = state.get_node_path(i)
		path_to_index[current_path] = i
		
		if i == 0:
			# 根节点，跳过父节点查找
			continue
		
		var parent_path: NodePath
		var name_count: int = current_path.get_name_count()
		
		if name_count <= 1:
			# 父节点是根节点，其路径在 SceneState 中表示为 "."
			parent_path = NodePath(".")
		else:
			# 移除最后一个名字，得到父路径
			var names: Array = []
			for k in range(name_count - 1):
				names.append(current_path.get_name(k))
			parent_path = NodePath("/".join(names))
		
		# 查找父节点索引
		if path_to_index.has(parent_path):
			var p_idx: int = path_to_index[parent_path]
			if not parent_map.has(p_idx): parent_map[p_idx] = []
			parent_map[p_idx].append(i)
		else:
			# 兜底：挂在根节点下
			if not parent_map.has(0): parent_map[0] = []
			parent_map[0].append(i)
	
	md += _build_tree_string(state, 0, "", true, parent_map)
	md += "```"
	return md


# 递归构建场景树字符串
static func _build_tree_string(p_state: SceneState, p_idx: int, p_prefix: String, p_is_last: bool, p_parent_map: Dictionary) -> String:
	var node_name: String = p_state.get_node_name(p_idx)
	var type: String = p_state.get_node_type(p_idx)
	
	# 获取脚本路径
	var script_path: String = ""
	for i in range(p_state.get_node_property_count(p_idx)):
		if p_state.get_node_property_name(p_idx, i) == "script":
			var script_res: Variant = p_state.get_node_property_value(p_idx, i)
			if script_res is Resource:
				script_path = script_res.resource_path
			break
	
	var line: String = p_prefix + ( "└─ " if p_is_last else "├─ " ) if p_idx != 0 else ""
	line += "%s (%s)" % [node_name, type]
	if not script_path.is_empty():
		line += " [script: `%s`]" % script_path
	
	line += "\n"
	
	var children: Array = p_parent_map.get(p_idx, [])
	var new_prefix: String = p_prefix + ( "   " if p_is_last else "│  " ) if p_idx != 0 else ""
	
	for i in range(children.size()):
		line += _build_tree_string(p_state, children[i], new_prefix, i == children.size() - 1, p_parent_map)
	
	return line


# 读取脚本文件内容（带行号）
static func _read_script_content(p_path: String) -> String:
	if not FileAccess.file_exists(p_path):
		return p_path
	
	var script: Resource = load(p_path)
	if script is GDScript and script.has_source_code():
		return "Content for Script: `%s`\n```gdscript\n%s\n```" % [p_path.get_file(), _add_line_numbers(script.source_code)]
	
	# 兜底
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if file:
		return "Content for Script: `%s`\n```gdscript\n%s\n```" % [p_path.get_file(), _add_line_numbers(file.get_as_text())]
	return p_path


# 读取着色器文件内容（带行号）
static func _read_shader_content(p_path: String) -> String:
	if not FileAccess.file_exists(p_path):
		return p_path
	
	var shader: Resource = load(p_path)
	if shader is Shader:
		return "Content for Shader: `%s`\n```glsl\n%s\n```" % [p_path.get_file(), _add_line_numbers(shader.get_code())]
	
	# 兜底
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if file:
		return "Content for Shader: `%s`\n```glsl\n%s\n```" % [p_path.get_file(), _add_line_numbers(file.get_as_text())]
	return p_path



# 读取资源文件内容
static func _read_resource_content(p_path: String) -> String:
	if not FileAccess.file_exists(p_path):
		return p_path
	
	var ext: String = p_path.get_extension().to_lower()
	
	# .tres 是纯文本，直接读取原始内容
	if ext == "tres":
		var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
		if file:
			var content: String = file.get_as_text()
			return "Content for Resource: `%s`\n```tres\n%s\n```" % [p_path.get_file(), content]
		return p_path
	
	# .res 是二进制，load() 后输出属性摘要
	var resource: Resource = load(p_path)
	if not resource:
		return p_path
	
	var md: String = "Content for Resource: `%s`\n" % p_path.get_file()
	md += "- **Type**: %s\n" % resource.get_class()
	md += "- **Path**: `%s`\n" % resource.resource_path
	if not resource.resource_name.is_empty():
		md += "- **Name**: %s\n" % resource.resource_name
	
	var has_props := false
	for p in resource.get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			if not has_props:
				md += "\n**Properties:**\n"
				has_props = true
			var val := resource.get(p.name)
			md += "- **%s**: %s\n" % [p.name, _format_property_value(val)]
	
	return md


# 将属性值转为安全的字符串表示
static func _format_property_value(p_val: Variant) -> String:
	match typeof(p_val):
		TYPE_STRING:
			return "\"%s\"" % p_val
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
			return str(p_val)
		TYPE_ARRAY:
			return "[Array: %d items]" % p_val.size()
		TYPE_DICTIONARY:
			return "[Dictionary: %d keys]" % p_val.size()
		TYPE_OBJECT:
			if p_val is Resource:
				return "[Resource: %s]" % p_val.resource_path.get_file()
			return str(p_val)
		_:
			return str(p_val)


# 为代码添加行号（右对齐，宽度根据总行数动态计算）
static func _add_line_numbers(p_source_code: String) -> String:
	var lines: PackedStringArray = p_source_code.split("\n")
	var total_lines: int = lines.size()
	var line_number_width: int = max(3, str(total_lines).length())
	
	var result: String = ""
	for i in range(total_lines):
		var line_number: String = str(i + 1)
		var padded_number: String = line_number.pad_zeros(line_number_width)
		result += "%s | %s" % [padded_number, lines[i]]
		if i < total_lines - 1:
			result += "\n"
	
	return result
