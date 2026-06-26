@tool
class_name FileContentReader
extends RefCounted

# ============================
#  场景树读取
# ============================

static func read_scene_content(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	var scene_resource: PackedScene = load(p_path)
	if not scene_resource:
		return {"success": false, "data": "Error: Failed to load scene: " + p_path}
	
	var scene_instance = scene_resource.instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
	if not is_instance_valid(scene_instance):
		return {"success": false, "data": "Error: Failed to instantiate scene: " + p_path}
	
	var tree_data: Dictionary = _build_scene_node_data(scene_instance)
	scene_instance.free()
	
	var md: String = "Context for Scene: `%s`\n```\n" % p_path.get_file()
	md += "Scene Tree Structure:\n"
	md += _format_scene_node(tree_data, "", true)
	md += "```\n"
	return {"success": true, "data": md}


static func _build_scene_node_data(p_node: Node) -> Dictionary:
	var node_data: Dictionary = {
		"name": p_node.name,
		"class": p_node.get_class(),
		"script": null,
		"children": []
	}
	var script = p_node.get_script()
	if is_instance_valid(script) and script.resource_path:
		node_data["script"] = script.resource_path
	for child in p_node.get_children():
		node_data["children"].append(_build_scene_node_data(child))
	return node_data


static func _format_scene_node(p_node_data: Dictionary, p_indent: String, p_is_last: bool) -> String:
	var line: String = p_indent
	if not p_indent.is_empty():
		line += "└─ " if p_is_last else "├─ "
	line += "%s (%s)" % [p_node_data.name, p_node_data.class]
	if p_node_data.script:
		line += " [script: `%s`]" % p_node_data.script
	var md: String = line + "\n"
	var new_indent: String = p_indent + ("   " if p_is_last else "│  ")
	for i in range(p_node_data.children.size()):
		md += _format_scene_node(p_node_data.children[i], new_indent, i == p_node_data.children.size() - 1)
	return md


# ============================
#  脚本读取（带行号）
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
	md += _add_line_numbers(source_code)
	md += "\n```\n"
	return {"success": true, "data": md}


static func _add_line_numbers(p_source_code: String) -> String:
	var lines: PackedStringArray = p_source_code.split("\n")
	var line_number_width: int = max(3, str(lines.size()).length())
	var result: String = ""
	for i in range(lines.size()):
		result += "%s | %s" % [str(i + 1).pad_zeros(line_number_width), lines[i]]
		if i < lines.size() - 1:
			result += "\n"
	return result


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
	
	var lang_tag: String = ""
	match extension:
		"json":      lang_tag = "json"
		"cfg":       lang_tag = "cfg"
		"tres":      lang_tag = "tres"
		"res":       lang_tag = "res"
		"gdshader":  lang_tag = "gdshader"
		"glsl":      lang_tag = "glsl"
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
	if p_bytes < 1024:        return "%d B" % p_bytes
	elif p_bytes < 1024 * 1024:         return "%.2f KB" % (p_bytes / 1024.0)
	elif p_bytes < 1024 * 1024 * 1024:   return "%.2f MB" % (p_bytes / (1024.0 * 1024.0))
	else:                      return "%.2f GB" % (p_bytes / (1024.0 * 1024.0 * 1024.0))
