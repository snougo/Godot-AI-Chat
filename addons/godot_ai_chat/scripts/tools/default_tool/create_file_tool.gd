@tool
extends AiTool

## 统一文件创建工具。
## 支持创建场景(.tscn)、脚本(.gd)、着色器(.gdshader) 和 Markdown(.md) 文件。


# --- Enums / Constants ---

## 允许的脚本扩展名
const SCRIPT_EXTENSIONS: Array[String] = ["gd"]

## 允许的着色器扩展名
const SHADER_EXTENSIONS: Array[String] = ["gdshader"]

## 禁止创建的文件名黑名单 (大小写不敏感)
const RESTRICTED_MARKDOWN_FILES: Array[String] = [
	"todo",
	"memory"
]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_file"
	tool_description = "Creates a new file. Supports: scene (.tscn), script (.gd), shader (.gdshader), markdown (.md)."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"file_type": {
				"type": "string",
				"enum": ["scene", "script", "shader", "markdown"],
				"description": "The type of file to create."
			},
			"path": {
				"type": "string",
				"description": "Target folder path (e.g., 'res://xxx/')."
			},
			"file_name": {
				"type": "string",
				"description": "File name with extension (e.g., 'xxxx.tscn' etc)."
			},
			"content": {
				"type": "string",
				"description": "Initial file content. Used for 'script', 'shader' and 'markdown' types."
			},
			"root_node_type": {
				"type": "string",
				"description": "Root node class name (e.g., 'Node2D', 'Node3D', 'Control' etc). Only for 'scene'. Default: 'Node'."
			},
			"root_node_name": {
				"type": "string",
				"description": "Root node name. Only for 'scene'. Defaults to file basename."
			}
		},
		"required": ["file_type", "path", "file_name"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var file_type: String = p_args.get("file_type", "")
	var folder_path: String = p_args.get("path", "")
	var file_name: String = p_args.get("file_name", "")
	
	if file_type.is_empty() or folder_path.is_empty() or file_name.is_empty():
		return {"success": false, "data": "Error: 'file_type', 'path', and 'file_name' are required."}
	
	# 确保文件夹路径以 / 结尾
	if not folder_path.ends_with("/"):
		folder_path += "/"
	
	var full_path: String = folder_path + file_name
	
	# 安全校验
	var safety_err: String = validate_path_safety(full_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	if FileAccess.file_exists(full_path):
		return {"success": false, "data": "Error: File already exists at %s. Overwriting is not allowed." % full_path}
	
	match file_type:
		"scene":
			return _create_scene(p_args, full_path, folder_path)
		"script":
			return _create_script(p_args, full_path, folder_path)
		"shader":
			return _create_shader(p_args, full_path, folder_path)
		"markdown":
			return _create_markdown(p_args, full_path, folder_path)
		_:
			return {"success": false, "data": "Error: Unknown file_type '%s'. Valid: scene, script, shader, markdown." % file_type}


# --- Private Functions ---

func _create_scene(p_args: Dictionary, p_full_path: String, p_folder_path: String) -> Dictionary:
	var ext: String = p_full_path.get_extension().to_lower()
	if ext != "tscn":
		return {"success": false, "data": "Error: Invalid extension '.%s'. Scene files must use '.tscn'." % ext}
	
	var type: String = p_args.get("root_node_type", "Node")
	var name: String = p_args.get("root_node_name", "")
	if name.is_empty():
		name = p_full_path.get_file().get_basename()
	
	var root: Node = _instantiate_node(type)
	if not root:
		return {"success": false, "data": "Error: Invalid root class/type: '%s'. Must be a Node subclass." % type}
	
	root.name = name
	var packed: PackedScene = PackedScene.new()
	var pack_result := packed.pack(root)
	
	if pack_result != OK:
		root.free()
		return {"success": false, "data": "Failed to pack scene. Error code: %d" % pack_result}
	
	# 确保目标文件夹存在
	if not DirAccess.dir_exists_absolute(p_folder_path):
		var dir := DirAccess.open("res://")
		if dir:
			dir.make_dir_recursive(p_folder_path)
	
	var err: Error = ResourceSaver.save(packed, p_full_path)
	if is_instance_valid(root):
		root.free()
	
	if err == OK:
		ToolBox.update_editor_filesystem(p_full_path)
		return {"success": true, "data": "Scene created: %s. Use `open_file` to open it." % p_full_path}
	
	return {"success": false, "data": "Failed to save scene. Error code: %d" % err}


func _create_script(p_args: Dictionary, p_full_path: String, p_folder_path: String) -> Dictionary:
	var ext: String = p_full_path.get_extension().to_lower()
	if ext not in SCRIPT_EXTENSIONS:
		return {"success": false, "data": "Error: Invalid extension '.%s'. Script files must use: .gd." % ext}
	
	var content: String = p_args.get("content", "")
	if content.is_empty():
		return {"success": false, "data": "Error: 'content' is required for file_type 'script'."}
	
	# 确保目标文件夹存在
	if not DirAccess.dir_exists_absolute(p_folder_path):
		var dir := DirAccess.open("res://")
		if dir:
			dir.make_dir_recursive(p_folder_path)
	
	var file := FileAccess.open(p_full_path, FileAccess.WRITE)
	if not file:
		return {"success": false, "data": "Failed to create script file: " + str(FileAccess.get_open_error())}
	
	file.store_string(content)
	file.close()
	
	ToolBox.update_editor_filesystem(p_full_path)
	return {"success": true, "data": "Script created: %s" % p_full_path}


func _create_shader(p_args: Dictionary, p_full_path: String, p_folder_path: String) -> Dictionary:
	var ext: String = p_full_path.get_extension().to_lower()
	if ext not in SHADER_EXTENSIONS:
		return {"success": false, "data": "Error: Invalid extension '.%s'. Shader files must use: .gdshader." % ext}
	
	var content: String = p_args.get("content", "")
	if content.is_empty():
		return {"success": false, "data": "Error: 'content' is required for file_type 'shader'."}
	
	# 确保目标文件夹存在
	if not DirAccess.dir_exists_absolute(p_folder_path):
		var dir := DirAccess.open("res://")
		if dir:
			dir.make_dir_recursive(p_folder_path)
	
	var file := FileAccess.open(p_full_path, FileAccess.WRITE)
	if not file:
		return {"success": false, "data": "Failed to create shader file: " + str(FileAccess.get_open_error())}
	
	file.store_string(content)
	file.close()
	
	ToolBox.update_editor_filesystem(p_full_path)
	return {"success": true, "data": "Shader created: %s" % p_full_path}


func _create_markdown(p_args: Dictionary, p_full_path: String, p_folder_path: String) -> Dictionary:
	var ext: String = p_full_path.get_extension().to_lower()
	if ext != "md":
		return {"success": false, "data": "Error: Invalid extension '.%s'. Markdown files must use '.md'." % ext}
	
	# 文件名黑名单检查
	var basename: String = p_full_path.get_file().get_basename().to_lower()
	if basename in RESTRICTED_MARKDOWN_FILES:
		return {
			"success": false,
			"data": "Security Error: Creation of '%s.md' is restricted. Use 'todo_list' or 'access_project_memory' tools instead." % basename
		}
	
	var content: String = p_args.get("content", "")
	if content.is_empty():
		return {"success": false, "data": "Error: 'content' is required for file_type 'markdown'."}
	
	# 确保目标文件夹存在
	if not DirAccess.dir_exists_absolute(p_folder_path):
		var dir := DirAccess.open("res://")
		if dir:
			dir.make_dir_recursive(p_folder_path)
	
	var file := FileAccess.open(p_full_path, FileAccess.WRITE)
	if not file:
		return {"success": false, "data": "Failed to create markdown file: " + str(FileAccess.get_open_error())}
	
	file.store_string(content)
	file.close()
	
	ToolBox.refresh_editor_filesystem()
	return {"success": true, "data": "Markdown file created: %s" % p_full_path}


# ==================== UTILITIES ====================

## 根据类型字符串实例化节点
func _instantiate_node(p_type_str: String) -> Node:
	if ClassDB.class_exists(p_type_str):
		if not ClassDB.is_parent_class(p_type_str, "Node"):
			return null
		var instance = ClassDB.instantiate(p_type_str)
		if instance is Node:
			return instance
	return null
