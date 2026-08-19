class_name FileContentReader
extends RefCounted

# ============================
#  场景树读取
# ============================

static func read_scene_content(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	# .tscn 是文本格式场景，复用文本读取逻辑直接返回文件内容
	if p_path.get_extension().to_lower() == "tscn":
		return read_text_content(p_path)
	
	# .scn 二进制场景：基于 SceneState 读取元信息（无需实例化，无副作用）
	var scene_resource: PackedScene = load(p_path)
	if not scene_resource:
		return {"success": false, "data": "Error: Failed to load scene: " + p_path}
	
	var md: String = "Content for Scene: `%s`\n" % p_path.get_file()
	md += "- **Type**: %s\n" % scene_resource.get_class()
	md += "- **Path**: `%s`\n" % scene_resource.resource_path
	md += "- **Can Instantiate**: %s\n" % str(scene_resource.can_instantiate())
	
	var state: SceneState = scene_resource.get_state() as SceneState
	if not state:
		return {"success": false, "data": "Error: Failed to get scene state: " + p_path}
	
	# 继承的基场景
	var base_state: SceneState = state.get_base_scene_state()
	if base_state:
		md += "- **Base Scene**: `%s`\n" % base_state.get_path()
	
	# 节点列表
	var node_count: int = state.get_node_count()
	md += "\n**Nodes:** (%d)\n" % node_count
	for i in range(node_count):
		md += _format_scene_state_node(state, i)
	
	# 信号连接
	var conn_count: int = state.get_connection_count()
	md += "\n**Connections:** (%d)\n" % conn_count
	for i in range(conn_count):
		md += _format_scene_state_connection(state, i)
	
	return {"success": true, "data": md}


# 格式化 SceneState 中的单个节点：路径、类型、子场景实例、组、导出/覆写属性
# [param p_state]: 场景状态
# [param p_idx]: 节点索引
# [return]: Markdown 格式的节点信息
static func _format_scene_state_node(p_state: SceneState, p_idx: int) -> String:
	var md: String = "- `%s` [%s]" % [p_state.get_node_path(p_idx), p_state.get_node_type(p_idx)]
	
	var instance: PackedScene = p_state.get_node_instance(p_idx)
	if instance:
		md += " [instance: `%s`]" % instance.resource_path
	elif p_state.is_node_instance_placeholder(p_idx):
		md += " [placeholder: `%s`]" % p_state.get_node_instance_placeholder(p_idx)
	
	var groups: PackedStringArray = p_state.get_node_groups(p_idx)
	if not groups.is_empty():
		md += " [groups: %s]" % ", ".join(groups)
	
	md += "\n"
	
	var prop_count: int = p_state.get_node_property_count(p_idx)
	for pi in range(prop_count):
		var pname: StringName = p_state.get_node_property_name(p_idx, pi)
		var pvalue: Variant = p_state.get_node_property_value(p_idx, pi)
		md += "  - **%s**: %s\n" % [pname, _format_property_value(pvalue)]
	
	return md


# 格式化 SceneState 中的单个信号连接：源/信号/目标/方法，附 flags 与 binds
# [param p_state]: 场景状态
# [param p_idx]: 连接索引
# [return]: Markdown 格式的连接信息
static func _format_scene_state_connection(p_state: SceneState, p_idx: int) -> String:
	var md: String = "- `%s.%s` -> `%s.%s`" % [
		p_state.get_connection_source(p_idx),
		p_state.get_connection_signal(p_idx),
		p_state.get_connection_target(p_idx),
		p_state.get_connection_method(p_idx)
	]
	var extras: Array[String] = []
	var flags: int = p_state.get_connection_flags(p_idx)
	if flags != 0:
		extras.append("flags=%d" % flags)
	var binds: Array = p_state.get_connection_binds(p_idx)
	if not binds.is_empty():
		extras.append("binds=%s" % binds)
	if not extras.is_empty():
		md += " (%s)" % ", ".join(extras)
	return md + "\n"


# ============================
#  脚本读取
# ============================

static func read_script_content(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	var resource: Resource = load(p_path)
	var source_code: String = ""
	
	if resource is Script:
		if not resource.has_source_code():
			return {"success": false, "data": "Error: Script has no source code: " + p_path}
		source_code = resource.source_code
	elif resource is Shader:
		source_code = resource.get_code()
		if source_code.is_empty():
			return {"success": false, "data": "Error: Shader has no source code: " + p_path}
	else:
		var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
		if not is_instance_valid(file):
			return {"success": false, "data": "Error: Failed to open file: " + p_path}
		source_code = file.get_as_text()
		file.close()
		if source_code.is_empty():
			return {"success": false, "data": "Error: File is empty: " + p_path}
	
	var file_name: String = p_path.get_file()
	var extension: String = p_path.get_extension().to_lower()
	var lang_tag: String = "gdscript"
	match extension:
		"gdshader", "gdshaderinc":  lang_tag = "gdshader"
		"glsl":                     lang_tag = "glsl"
	
	var md: String = "Content for Script: `%s`\n" % file_name
	md += "```%s\n" % lang_tag
	#md += _add_line_numbers(source_code)
	# 现在可以通过工具 ge_code_line_number 来精确获取代码行号了
	md += source_code
	md += "\n```\n"
	return {"success": true, "data": md}


#static func _add_line_numbers(p_source_code: String) -> String:
	#var lines: PackedStringArray = p_source_code.split("\n")
	#var line_number_width: int = max(3, str(lines.size()).length())
	#var result: String = ""
	#for i in range(lines.size()):
		#result += "%s | %s" % [str(i + 1).pad_zeros(line_number_width), lines[i]]
		#if i < lines.size() - 1:
			#result += "\n"
	#return result


# ============================
#  资源文件读取（.tres / .res）
# ============================

static func read_resource_content(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	var ext: String = p_path.get_extension().to_lower()
	
	# .tres 是纯文本，复用文本读取逻辑
	if ext == "tres":
		return read_text_content(p_path)
	
	# .res 是二进制，用 load() 取元信息
	var resource: Resource = load(p_path)
	if not resource:
		return {"success": false, "data": "Error: Failed to load resource: " + p_path}
	
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
			md += "- **%s**: %s\n" % [p.name, _format_property_value(resource.get(p.name))]
	
	return {"success": true, "data": md}


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


# ============================
#  文本文件读取
# ============================

static func read_text_content(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not is_instance_valid(file):
		return {"success": false, "data": "Error: Failed to open file: " + p_path}
	var content: String = file.get_as_text()
	file.close()
	
	var extension: String = p_path.get_extension().to_lower()
	if extension == "json":
		var json: JSON = JSON.new()
		if json.parse(content) == OK:
			content = JSON.stringify(json.get_data(), "\t")
	
	var file_name: String = p_path.get_file()
	var md: String = "Content for File: `%s`\n" % file_name
	
	if extension in ["txt", "md"]:
		md += "\n" + content + "\n"
		return {"success": true, "data": md}
	
	# 语言标签：默认使用扩展名本身，仅少数格式映射到通用标签
	var lang_tag: String = extension
	match extension:
		"godot", "import":  lang_tag = "ini"
	
	md += "```%s\n%s\n```\n" % [lang_tag, content]
	return {"success": true, "data": md}


# ============================
#  图片元数据读取
# ============================

static func read_image_metadata(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	var supported_extensions: Array = ["png", "jpg", "jpeg", "svg"]
	var extension: String = p_path.get_extension().to_lower()
	if extension not in supported_extensions:
		return {"success": false, "data": "Error: Unsupported image format: " + extension}
	
	var texture: Texture2D = load(p_path)
	if not is_instance_valid(texture):
		return {"success": false, "data": "Error: Failed to load image: " + p_path}
	
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not is_instance_valid(file):
		return {"success": false, "data": "Error: Failed to open image file: " + p_path}
	var file_size_bytes: int = file.get_length()
	file.close()
	
	var file_name: String = p_path.get_file()
	var md: String = "Context for Image: `%s`\n\n" % file_name
	md += "*   **Path**: `%s`\n" % p_path
	md += "*   **Dimensions**: %d x %d pixels\n" % [texture.get_width(), texture.get_height()]
	md += "*   **File Size**: %s\n" % _format_bytes(file_size_bytes)
	return {"success": true, "data": md}


static func _format_bytes(p_bytes: int) -> String:
	if p_bytes < 1024:
		return "%d B" % p_bytes
	elif p_bytes < 1024 * 1024:
		return "%.2f KB" % (p_bytes / 1024.0)
	elif p_bytes < 1024 * 1024 * 1024:
		return "%.2f MB" % (p_bytes / (1024.0 * 1024.0))
	else:
		return "%.2f GB" % (p_bytes / (1024.0 * 1024.0 * 1024.0))
