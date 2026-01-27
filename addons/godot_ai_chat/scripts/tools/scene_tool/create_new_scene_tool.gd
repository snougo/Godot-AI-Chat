@tool
extends BaseSceneTool

## 创建一个新的场景文件（.tscn），包含指定的内置根节点。

# --- Enums / Constants ---

## 允许的扩展名白名单
const ALLOWED_EXTENSIONS: Array[String] = ["tscn"]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_new_scene"
	tool_description = "Create a new EMPTY `.tscn` file with a specified built-in root node."


# --- Public Functions ---

## 获取工具参数的 JSON Schema
func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"scene_path": { 
				"type": "string", 
				"description": "The full path where the `.tscn` file should be saved." 
			},
			"root_type": {
				"type": "string",
				"description": "The Godot class name for the root node (e.g., 'Node/2D/3D', 'Control' etc). Default is 'Node'."
			},
			"root_name": {
				"type": "string",
				"description": "The name of the root node. If not provided, it defaults to the file name (without extension)."
			}
		},
		"required": ["scene_path"]
	}


## 执行创建场景操作
## [param p_args]: 包含 scene_path, root_type, root_name 的参数字典
## [return]: 操作结果字典
func execute(p_args: Dictionary) -> Dictionary:
	var scene_path: String = p_args.get("scene_path", "")
	var root_type: String = p_args.get("root_type", "Node")
	var root_name: String = p_args.get("root_name", "")
	
	if root_type.is_empty():
		root_type = "Node"
	
	# 1. 验证路径
	var validation_result: Dictionary = _validate_scene_path(scene_path)
	if not validation_result.get("success", false):
		return validation_result
	
	if FileAccess.file_exists(scene_path):
		return {"success": false, "data": "File already exists: %s" % scene_path}
	
	# 2. 实例化根节点
	var root_node: Node = _instantiate_node_by_type(root_type)
	if not root_node:
		return {"success": false, "data": "Invalid root_type: '%s'. Must be a valid Godot ClassName." % root_type}
	
	# 3. 设置节点名称
	if root_name.is_empty():
		root_name = scene_path.get_file().get_basename()
	root_node.name = root_name
	
	# 4. 保存场景
	return _save_scene(root_node, scene_path)


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


## 根据类型字符串实例化节点
## [param p_type_str]: 类型字符串（仅限内置类名）
## [return]: 实例化的节点，失败返回 null
func _instantiate_node_by_type(p_type_str: String) -> Node:
	# 仅允许 Godot 内置类型
	if ClassDB.class_exists(p_type_str):
		return ClassDB.instantiate(p_type_str)
	
	return null


## 保存场景
## [param p_root_node]: 根节点
## [param p_scene_path]: 场景路径
## [return]: 操作结果字典
func _save_scene(p_root_node: Node, p_scene_path: String) -> Dictionary:
	var packed_scene := PackedScene.new()
	var result := packed_scene.pack(p_root_node)
	
	if result != OK:
		p_root_node.free()
		return {"success": false, "data": "Failed to pack scene: %d" % result}
	
	var base_dir: String = p_scene_path.get_base_dir()
	if not DirAccess.dir_exists_absolute(base_dir):
		p_root_node.free()
		return {"success": false, "data": "Directory not found: %s. Please use 'create_folder' tool first." % base_dir}
	
	var err: Error = ResourceSaver.save(packed_scene, p_scene_path)
	
	# 清理内存中的节点
	p_root_node.free()
	
	if err == OK:
		ToolBox.update_editor_filesystem(p_scene_path)
		return {"success": true, "data": "Scene created at %s" % p_scene_path}
	else:
		return {"success": false, "data": "Save Failed: %d" % err}
