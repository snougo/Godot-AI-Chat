@tool
extends QuickModelToolBase

## 导出：把 QuickModel 的多边形数据写成独立 ArrayMesh（带法线），供运行时使用。


func _init() -> void:
	tool_name = "quick_model_export"
	tool_description = (
		"Exports a QuickModel's geometry as a standalone ArrayMesh resource (.tres/.res) that can be used at runtime "
		+ "(drag it into a MeshInstance3D). This is a plain Godot resource — no plugin dependency at runtime. "
		+ "The editable polygon data stays in the .tscn; exporting does not freeze or replace the QuickModel. "
		+ "Path must be writable (not under res://addons). "
		+ "Tip: after exporting, save the scene too, so the QuickModel's own state is persisted."
	)


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"path": {
				"type": "string",
				"description": "Output path, e.g. 'res://models/crate.tres'. '.tres' is appended if missing. Required."
			},
			"node_path": {
				"type": "string",
				"description": "Path of the QuickModel node. Omit to use the one selected in the editor."
			},
			"set_save_path": {
				"type": "boolean",
				"description": "Also write the path into the node's Inspector 'save_path' property. Default true."
			},
			"save": {
				"type": "boolean",
				"description": "Save the scene after exporting. Default false."
			}
		},
		"required": ["path"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var api_instance: Object = api()
	if api_instance == null:
		return ToolResult.fail(missing_plugin_error())
	
	var path: String = text_of(p_args, "path")
	if path.is_empty():
		return ToolResult.fail("'path' is required, e.g. 'res://models/crate.tres'.")
	
	var safety: String = validate_path_safety(path)
	if not safety.is_empty():
		return ToolResult.fail(safety)
	
	var resolved: Dictionary = resolve_model(p_args)
	if resolved.model == null:
		return ToolResult.fail(str(resolved.error))
	
	var result: Dictionary = api_instance.call(
		"export_mesh",
		resolved.model,
		path,
		bool(p_args.get("set_save_path", true))
	)
	
	return respond_op(p_args, resolved.model, result)
