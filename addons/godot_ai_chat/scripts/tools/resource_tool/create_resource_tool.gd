@tool
extends BaseResourceTool

## 新建资源文件。可以一次带上初始属性——省掉"先 create 再 edit"的两步。
## 只接受可实例化的具体类型；基类会被拒绝，因为存出来是空文件。

func _init() -> void:
	tool_name = "create_resource"
	tool_description = "Creates a new .tres/.res resource, optionally with initial properties."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Target folder. It must already exist."
			},
			"file_name": {
				"type": "string",
				"description": "Bare file name with .tres or .res, e.g. 'stone.tres'. A directory here is rejected."
			},
			"resource_type": {
				"type": "string",
				"description": "Concrete Resource class or a project script class name. Base types (Resource) are rejected."
			},
			"properties": {
				"type": "object",
				"description": "Optional initial properties. Nothing is created unless every value is valid."
			}
		},
		"required": ["path", "file_name", "resource_type"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var unknown: String = check_params(p_args, ["path", "file_name", "resource_type", "properties"])
	if not unknown.is_empty():
		return ToolResult.fail(unknown)
	
	var folder: String = text_of(p_args, "path")
	var file_name: String = text_of(p_args, "file_name")
	var type_name: String = text_of(p_args, "resource_type")
	
	if folder.is_empty() or file_name.is_empty() or type_name.is_empty():
		return ToolResult.fail("'path', 'file_name' and 'resource_type' are required.")
	if not folder.begins_with("res://"):
		return ToolResult.fail("'path' must start with res://.")
	if not folder.ends_with("/"):
		folder += "/"
	
	if file_name.contains("/"):
		return ToolResult.fail("'file_name' must be a bare file name — put the directory in 'path'.")
	
	if not DirAccess.dir_exists_absolute(folder):
		return ToolResult.fail("Folder does not exist: %s. Create it first." % folder)
	
	var full_path: String = folder + file_name
	if full_path.get_extension().to_lower() not in RESOURCE_EXTENSIONS:
		return ToolResult.fail("'%s' must end with .tres or .res." % file_name)
	
	var safety: String = validate_path_safety(full_path)
	if not safety.is_empty():
		return ToolResult.fail(safety)
	
	if FileAccess.file_exists(full_path):
		return ToolResult.fail("File already exists: %s. Use edit_resource instead of overwriting." % full_path)

	if type_name in BASE_RESOURCE_TYPES:
		return ToolResult.fail("'%s' is a base type — a file created from it would contain nothing. Pick a concrete subclass.%s" % [type_name, candidate_suffix(resource_candidates(type_name))])
	
	var resource: Resource = instantiate_resource_by_class(type_name)
	if resource == null:
		return ToolResult.fail("'%s' is not an instantiable Resource class.%s" % [type_name, candidate_suffix(resource_candidates(type_name))])
	
	var rows: Array[Dictionary] = []
	var props_raw: Variant = p_args.get("properties")
	
	if props_raw != null:
		if not (props_raw is Dictionary):
			return ToolResult.fail("'properties' must be an object mapping property names to values.")
		var props: Dictionary = props_raw
		var writes: Array[Dictionary] = []
		var problems: Array[String] = []
		
		for raw_key in props.keys():
			var key: String = str(raw_key)
			var split: Dictionary = split_property_key(key)
			if not bool(split.get("ok", false)):
				problems.append(str(split.get("error", "")))
				continue
			
			var sub: Array = split.get("sub_path", [])
			var write: Dictionary = resolve_property_write(resource, str(split.get("property", "")), sub, props[raw_key])
			if not bool(write.get("ok", false)):
				problems.append("'%s': %s" % [key, str(write.get("error", ""))])
				continue
			
			write["key"] = key
			writes.append(write)
		
		if not problems.is_empty():
			return ToolResult.fail("Nothing was created — invalid property value(s):\n%s" % "\n".join(PackedStringArray(problems)))
		
		for write: Dictionary in writes:
			var indexed: String = str(write.get("indexed"))
			resource.set_indexed(indexed, write.get("value"))
			rows.append({"property": indexed, "value": json_safe(resource.get_indexed(indexed))})
	
	# 让内存实例与这个路径绑定，再写盘
	resource.take_over_path(full_path)
	var save_error: String = save_resource_file(resource, full_path)
	if not save_error.is_empty():
		return ToolResult.fail(save_error)
	
	var summary: Dictionary = {
		"ok": true,
		"path": full_path,
		"resource_type": resource.get_class(),
		"script": script_path_of(resource),
		"properties": rows,
	}
	
	return ToolResult.ok(JSON.stringify(summary, "\t") + "\n\nOpen it with `open_file`, or keep editing with `edit_resource`.")
