@tool
extends QuickModelToolBase

## 删除选中元素所在的面（整面删除），并清理不再被引用的顶点。


func _init() -> void:
	tool_name = "quick_model_delete"
	tool_description = (
		"Deletes the faces touched by the target components and cleans up vertices that no longer belong to any face. "
		+ "Face mode deletes the selected faces; edge mode deletes every face using a selected edge; "
		+ "vertex mode deletes every face using a selected vertex. Whole-face deletion only — no dissolve/hole cutting. "
		+ "Vertex and face indices are renumbered afterwards, so re-read the mesh with quick_model_inspect before the next step."
	)


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Path of the QuickModel node. Omit to use the one selected in the editor."
			},
			"mode": {
				"type": "string",
				"enum": ["vertex", "edge", "face"],
				"description": "Which components to delete by. Default: the node's current mode."
			},
			"indices": {
				"type": "array",
				"items": { "type": "integer" },
				"description": "Explicit component indices."
			},
			"all": {
				"type": "boolean",
				"description": "Delete everything (empties the mesh)."
			},
			"axis": {
				"type": "string",
				"description": "Predicate: only components whose face normal matches this direction, e.g. '+y'."
			},
			"normal": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Predicate: custom direction [x,y,z] matched against face normals."
			},
			"tolerance": {
				"type": "number",
				"description": "Angle tolerance in degrees for axis/normal. Default 20."
			},
			"boundary": {
				"type": "boolean",
				"description": "Edge mode: only boundary edges."
			},
			"near": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Predicate: only components whose center is within 'radius' of this local point [x,y,z]."
			},
			"radius": {
				"type": "number",
				"description": "Radius for 'near'."
			},
			"save": {
				"type": "boolean",
				"description": "Save the scene after the change. Default false."
			}
		}
	}


func execute(p_args: Dictionary) -> ToolResult:
	var api_instance: Object = api()
	if api_instance == null:
		return ToolResult.fail(missing_plugin_error())
	
	var resolved: Dictionary = resolve_target(p_args)
	if not str(resolved.error).is_empty():
		return ToolResult.fail(str(resolved.error))
	
	var result: Dictionary = api_instance.call("delete", resolved.model, int(resolved.mode), resolved.indices)
	
	return respond_op(p_args, resolved.model, result)
