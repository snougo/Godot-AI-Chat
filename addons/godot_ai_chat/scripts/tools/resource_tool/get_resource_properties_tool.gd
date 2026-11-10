@tool
extends BaseResourceTool

## 列出资源的可编辑属性。默认只给"字符串值 + 类型"，需要结构化值或子资源时再打开开关。

func _init() -> void:
	tool_name = "get_resource_properties"
	tool_description = "Lists the editable properties of a .tres/.res: value, type, and attached resource."


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Full path of an existing .tres/.res file."
			},
			"include_raw": {
				"type": "boolean",
				"description": "Also return JSON-safe values. Default false."
			},
			"include_sub_resources": {
				"type": "boolean",
				"description": "Also list the editable properties of each attached sub-resource. Default false."
			}
		},
		"required": ["path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var unknown: String = check_params(p_args, ["path", "include_raw", "include_sub_resources"])
	if not unknown.is_empty():
		return ToolResult.fail(unknown)
	
	var path: String = text_of(p_args, "path")
	
	var loaded: Dictionary = load_resource_file(path)
	if loaded.resource == null:
		return ToolResult.fail(str(loaded.error))
	
	var resource: Resource = loaded.resource
	
	var summary: Dictionary = {
		"path": path,
		"type": resource.get_class(),
		"script": script_path_of(resource),
		"properties": get_all_object_properties(
			resource,
			flag_of(p_args, "include_raw"),
			flag_of(p_args, "include_sub_resources")),
	}
	
	return ToolResult.ok(JSON.stringify(summary, "\t"))
