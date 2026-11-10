@tool
extends QuickModelToolBase

## 倒角（Bevel）：把选中边削成切角（1 段）或圆角（多段）。


func _init() -> void:
	tool_name = "quick_model_bevel"
	tool_description = (
		"Bevels edges of a QuickModel: width is the chamfer/round distance, segments=1 gives a flat chamfer, "
		+ "2..8 gives a rounded edge. Only interior edges (exactly two adjacent faces) can be bevelled; boundary "
		+ "or non-manifold edges are skipped. Multi-segment requires valence-3 vertices and at most 2 selected edges "
		+ "per vertex, otherwise it silently falls back to 1 segment. "
		+ "Targets come from the node's current edge selection or a predicate (all / boundary / axis / normal / near+radius / indices)."
	)


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Path of the QuickModel node. Omit to use the one selected in the editor."
			},
			"width": {
				"type": "number",
				"description": "Bevel width in local units. Required, > 0. Clamped automatically if it exceeds adjacent edge lengths."
			},
			"segments": {
				"type": "integer",
				"minimum": 1,
				"maximum": 8,
				"description": "1 = flat chamfer (default), 2..8 = rounded."
			},
			"result_mode": {
				"type": "string",
				"enum": ["edge", "face"],
				"description": "What stays selected afterwards: 'edge' (default) = the new offset edges; 'face' = the new chamfer faces."
			},
			"indices": {
				"type": "array",
				"items": { "type": "integer" },
				"description": "Explicit edge indices."
			},
			"all": {
				"type": "boolean",
				"description": "Bevel every edge."
			},
			"boundary": {
				"type": "boolean",
				"description": "Predicate: only boundary edges (one adjacent face). These are skipped by bevel, so this is mainly for inspection."
			},
			"axis": {
				"type": "string",
				"description": "Predicate: only edges whose adjacent face normal matches this direction, e.g. '+y'."
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
				"description": "Predicate: only edges whose midpoint is within 'radius' of this local point [x,y,z]."
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
		"required": ["width"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var api_instance: Object = api()
	if api_instance == null:
		return ToolResult.fail(missing_plugin_error())
	
	var width: float = float(p_args.get("width", 0.0))
	if width <= 0.0:
		return ToolResult.fail("'width' is required and must be greater than 0.")
	
	var args: Dictionary = with_default_mode(p_args, "edge")
	var resolved: Dictionary = resolve_target(args)
	if not str(resolved.error).is_empty():
		return ToolResult.fail(str(resolved.error))
	
	var result_mode_text: String = text_of(p_args, "result_mode", "edge").to_lower()
	var result_mode: int = int(api_instance.call("mode_from_name", result_mode_text))
	if result_mode != int(api_instance.call("mode_from_name", "face")):
		result_mode = int(api_instance.call("mode_from_name", "edge"))
	
	var segments: int = clampi(int(p_args.get("segments", 1)), 1, 8)
	
	var result: Dictionary = api_instance.call(
		"bevel",
		resolved.model,
		resolved.indices,
		width,
		segments,
		result_mode
	)
	
	return respond_op(p_args, resolved.model, result)
