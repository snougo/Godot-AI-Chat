@tool
extends AiTool

## 场景文件创建工具。
## 只能创建场景(.tscn)文件，用于 Scene Builder 技能。
## 注意：目标文件夹必须已存在，不会自动创建。


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_scene"
	tool_description = "Creates a new Godot scene (.tscn) file."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Target folder path (e.g., 'res://xxx/'). The folder must already exist."
			},
			"file_name": {
				"type": "string",
				"description": "File name with .tscn extension (e.g., 'my_scene.tscn')."
			},
			"root_node_type": {
				"type": "string",
				"description": "Root node class name (e.g., 'Node2D', 'Control', 'CharacterBody2D'). Default: 'Node'."
			},
			"root_node_name": {
				"type": "string",
				"description": "Root node name. Defaults to file basename."
			}
		},
		"required": ["path", "file_name"]
	}


func execute(p_args: Dictionary) -> Dictionary:
	var folder_path: String = p_args.get("path", "")
	var file_name: String = p_args.get("file_name", "")
	
	if folder_path.is_empty() or file_name.is_empty():
		return {"success": false, "data": "Error: 'path' and 'file_name' are required."}
	
	# 确保文件夹路径以 / 结尾
	if not folder_path.ends_with("/"):
		folder_path += "/"
	
	var full_path: String = folder_path + file_name
	
	# 安全校验
	var safety_err: String = validate_path_safety(full_path)
	if not safety_err.is_empty():
		return {"success": false, "data": safety_err}
	
	# 检查文件是否已存在
	if FileAccess.file_exists(full_path):
		return {"success": false, "data": "Error: File already exists at %s. Overwriting is not allowed." % full_path}
	
	# 检查目标文件夹是否存在（禁止越权创建文件夹）
	if not DirAccess.dir_exists_absolute(folder_path):
		return {"success": false, "data": "Error: Target folder '%s' does not exist. Use `manage_folder` to create it first." % folder_path}
	
	# 强制校验扩展名
	var ext: String = full_path.get_extension().to_lower()
	if ext != "tscn":
		return {"success": false, "data": "Error: Invalid extension '.%s'. Scene files must use '.tscn'." % ext}
	
	# 创建场景
	var type: String = p_args.get("root_node_type", "Node")
	var name: String = p_args.get("root_node_name", "")
	if name.is_empty():
		name = full_path.get_file().get_basename()
	
	var root: Node = _instantiate_node(type)
	if not root:
		return {"success": false, "data": "Error: Invalid root class/type: '%s'. Must be a Node subclass." % type}
	
	root.name = name
	var packed: PackedScene = PackedScene.new()
	var pack_result := packed.pack(root)
	
	if pack_result != OK:
		root.free()
		return {"success": false, "data": "Failed to pack scene. Error code: %d" % pack_result}
	
	var err: Error = ResourceSaver.save(packed, full_path)
	if is_instance_valid(root):
		root.free()
	
	if err == OK:
		ToolBox.update_editor_filesystem(full_path)
		return {"success": true, "data": "Scene created: %s. Use `open_file` to open it." % full_path}
	
	return {"success": false, "data": "Failed to save scene. Error code: %d" % err}


# --- Private Functions ---

# 根据类型字符串实例化节点
func _instantiate_node(p_type_str: String) -> Node:
	if ClassDB.class_exists(p_type_str):
		if not ClassDB.is_parent_class(p_type_str, "Node"):
			return null
		var instance = ClassDB.instantiate(p_type_str)
		if instance is Node:
			return instance
	return null
