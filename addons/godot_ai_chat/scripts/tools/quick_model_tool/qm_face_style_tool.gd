@tool
extends QuickModelToolBase

## 面样式：平滑着色 / 平直着色 / 翻转法线（只改标志与绕序，不改拓扑）。


func _init() -> void:
	tool_name = "quick_model_face_style"
	tool_description = (
		"Changes face shading on a QuickModel: 'shade_smooth' (Gouraud-like, shares vertex normals), "
		+ "'shade_flat' (hard faceted edges), or 'flip_normals' (reverses face winding, fixing inside-out faces). "
		+ "Geometry and indices are unchanged. Targets are faces: from the node's current face selection, "
		+ "or from a predicate (all / axis / normal / near+radius / indices)."
	)


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["shade_smooth", "shade_flat", "flip_normals"],
				"description": "What to do with the target faces. Required."
			},
			"node_path": {
				"type": "string",
				"description": "Path of the QuickModel node. Omit to use the one selected in the editor."
			},
			"indices": {
				"type": "array",
				"items": { "type": "integer" },
				"description": "Explicit face indices."
			},
			"all": {
				"type": "boolean",
				"description": "Apply to every face."
			},
			"axis": {
				"type": "string",
				"description": "Predicate: only faces whose normal matches this direction, e.g. '+y'."
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
			"smooth": {
				"type": "boolean",
				"description": "Predicate: true = only faces that are currently smooth, false = only flat ones."
			},
			"near": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Predicate: only faces whose center is within 'radius' of this local point [x,y,z]."
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
		"required": ["action"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var api_instance: Object = api()
	if api_instance == null:
		return ToolResult.fail(missing_plugin_error())
	
	var action: String = text_of(p_args, "action").to_lower()
	if not (action in ["shade_smooth", "shade_flat", "flip_normals"]):
		return ToolResult.fail("'action' must be shade_smooth, shade_flat or flip_normals.")
	
	var args: Dictionary = with_default_mode(p_args, "face")
	var resolved: Dictionary = resolve_target(args, ["indices", "all", "axis", "normal", "near", "radius", "tolerance", "smooth"])
	if not str(resolved.error).is_empty():
		return ToolResult.fail(str(resolved.error))
	
	var indices: PackedInt32Array = resolved.indices
	var result: Dictionary
	
	match action:
		"shade_smooth":
			result = api_instance.call("shade", resolved.model, indices, true)
		"shade_flat":
			result = api_instance.call("shade", resolved.model, indices, false)
		_:
			result = api_instance.call("flip_normals", resolved.model, indices)
	
	return respond_op(p_args, resolved.model, result)
