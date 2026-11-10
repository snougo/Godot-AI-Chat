@tool
extends QuickModelToolBase

## 连接顶点（Connect Vertex Path / J）：把同一面内的选中顶点连成割线，切开该面。


func _init() -> void:
	tool_name = "quick_model_connect"
	tool_description = (
		"Connects selected vertices inside a face of a QuickModel, splitting that face along the new edge "
		+ "(Blender's Connect Vertex Path / J). Use it to clean up n-gons left behind by bevel. "
		+ "Vertices must sit in the same face and must not be adjacent (adjacent vertices are already connected by an edge). "
		+ "Repeating it on the same face subdivides further. Vertex mode; the selection is kept afterwards."
	)


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Path of the QuickModel node. Omit to use the one selected in the editor."
			},
			"indices": {
				"type": "array",
				"items": { "type": "integer" },
				"description": "Vertex indices to connect (at least 2)."
			},
			"all": {
				"type": "boolean",
				"description": "Use every vertex (rarely useful)."
			},
			"axis": {
				"type": "string",
				"description": "Predicate: only vertices whose adjacent face normal matches this direction, e.g. '+y'."
			},
			"normal": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Predicate: custom direction [x,y,z] matched against adjacent face normals."
			},
			"tolerance": {
				"type": "number",
				"description": "Angle tolerance in degrees for axis/normal. Default 20."
			},
			"near": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Predicate: only vertices within 'radius' of this local point [x,y,z]."
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
	
	# 连接顶点只对顶点有意义
	var args: Dictionary = with_default_mode(p_args, "vertex")
	var resolved: Dictionary = resolve_target(args, ["indices", "all", "axis", "normal", "near", "radius", "tolerance"])
	if not str(resolved.error).is_empty():
		return ToolResult.fail(str(resolved.error))
	
	var result: Dictionary = api_instance.call("connect_vertices", resolved.model, resolved.indices)
	
	return respond_op(p_args, resolved.model, result)
