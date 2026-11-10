@tool
extends QuickModelToolBase

## 面 / 边挤出。操作后新生成的顶面（或新偏移边）保持选中，可连续挤出。


func _init() -> void:
	tool_name = "quick_model_extrude"
	tool_description = (
		"Extrudes the target faces or edges of a QuickModel. Face mode: 'individual'=false extrudes the selection as one "
		+ "region (shared interior edges produce no side walls), true extrudes each face along its own normal. "
		+ "Edge mode: copies the selected edges and spans a quad per edge. "
		+ "The new top faces / new offset edges stay selected, so repeated calls chain naturally. "
		+ "Targets come from the node's current selection or from a predicate (all / axis / normal / near+radius / indices)."
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
				"enum": ["face", "edge"],
				"description": "Extrude faces (default) or edges."
			},
			"distance": {
				"type": "number",
				"description": "Extrusion distance in local units. Negative extrudes inward. Required, non-zero."
			},
			"direction": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Extrusion direction [x,y,z]. Omit to use the average normal of the target faces."
			},
			"individual": {
				"type": "boolean",
				"description": "Face mode only: true = extrude each face independently along its own normal. Default false (region)."
			},
			"indices": {
				"type": "array",
				"items": { "type": "integer" },
				"description": "Explicit face/edge indices (interpreted in 'mode')."
			},
			"all": {
				"type": "boolean",
				"description": "Extrude every face/edge of the mode."
			},
			"axis": {
				"type": "string",
				"description": "Predicate: only extrude components whose face normal points along this direction, e.g. '+y'."
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
		},
		"required": ["distance"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var api_instance: Object = api()
	if api_instance == null:
		return ToolResult.fail(missing_plugin_error())
	
	var distance: float = float(p_args.get("distance", 0.0))
	if is_zero_approx(distance):
		return ToolResult.fail("'distance' is required and must be non-zero.")
	
	var args: Dictionary = with_default_mode(p_args, "face")
	var resolved: Dictionary = resolve_target(args)
	if not str(resolved.error).is_empty():
		return ToolResult.fail(str(resolved.error))
	
	var result: Dictionary = api_instance.call(
		"extrude",
		resolved.model,
		int(resolved.mode),
		resolved.indices,
		vec3_of(args.get("direction", [])),
		distance,
		bool(args.get("individual", false))
	)
	
	return respond_op(p_args, resolved.model, result)
