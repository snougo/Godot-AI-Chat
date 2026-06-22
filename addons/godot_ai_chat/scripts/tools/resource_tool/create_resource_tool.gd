@tool
extends AiTool

## 资源文件创建工具。
## 通过引擎 API 合法创建 Resource 资源文件(.tres/.res)。
## 使用 ClassDB.instantiate() 实例化后，通过 ResourceSaver.save() 保存。
## 注意：目标文件夹必须已存在，不会自动创建。
## 务必指定 resource_type 为具体的资源子类（如 StyleBoxFlat），避免使用基类 Resource。


# --- Enums / Constants ---

## 允许的资源文件扩展名
const RESOURCE_EXTENSIONS: Array[String] = ["tres", "res"]


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "create_resource"
	tool_description = "Creates a new Resource (.tres/.res) file."


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
				"description": "File name with .tres or .res extension (e.g., 'my_resource.tres')."
			},
			"resource_type": {
				"type": "string",
				"description": "Concrete Resource subclass name to instantiate."
			}
		},
		"required": ["path", "file_name", "resource_type"]
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
	if ext not in RESOURCE_EXTENSIONS:
		return {"success": false, "data": "Error: Invalid extension '.%s'. Resource files must use: .tres (text) or .res (binary)." % ext}
	
	# 创建资源
	var type: String = p_args.get("resource_type", "Resource")
	
	var resource: Resource = _instantiate_resource(type)
	if not resource:
		return {"success": false, "data": "Error: Invalid resource type '%s'. Must be a Resource subclass." % type}
	
	var err: Error = ResourceSaver.save(resource, full_path)
	
	if err == OK:
		ToolBox.update_editor_filesystem(full_path)
		return {"success": true, "data": "Resource created: %s (type: %s). Use `open_file` to open it." % [full_path, type]}
	
	return {"success": false, "data": "Failed to save resource. Error code: %d" % err}


# --- Private Functions ---

# 根据类型字符串实例化资源
# 通过 ClassDB 动态创建指定类型的 Resource 实例
func _instantiate_resource(p_type_str: String) -> Resource:
	if ClassDB.class_exists(p_type_str):
		if not ClassDB.is_parent_class(p_type_str, "Resource"):
			return null
		var instance = ClassDB.instantiate(p_type_str)
		if instance is Resource:
			return instance
	return null
