@tool
extends QuickModelToolBase

## 内插面（Inset）。区域式把相邻选中面当作一个区域，只在外圈长侧面。


func _init() -> void:
	tool_name = "quick_model_inset"
	tool_description = (
		"Inset faces of a QuickModel: shrinks the selected faces inward and grows a side-wall ring on the region border. "
		+ "individual=false (default) treats adjacent selected faces as ONE region; individual=true insets every face "
		+ "separately (Blender's 'Individual Faces Inset'). The new inner faces stay selected. Face mode only."
	)


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Path of the QuickModel node. Omit to use the one selected in the editor."
			},
			"amount": {
				"type": "number",
				"description": "Inset distance (perpendicular from the border edges, local units). Required, > 0."
			},
			"individual": {
				"type": "boolean",
				"description": "true = inset each face independently. Default false (region)."
			},
			"indices": {
				"type": "array",
				"items": { "type": "integer" },
				"description": "Explicit face indices."
			},
			"all": {
				"type": "boolean",
				"description": "Inset every face."
			},
			"axis": {
				"type": "string",
				"description": "Predicate: only faces whose normal points along this direction, e.g. '+y'."
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
		"required": ["amount"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var api_instance: Object = api()
	if api_instance == null:
		return ToolResult.fail(missing_plugin_error())
	
	var amount: float = float(p_args.get("amount", 0.0))
	if amount <= 0.0:
		return ToolResult.fail("'amount' is required and must be greater than 0.")
	
	var args: Dictionary = with_default_mode(p_args, "face")
	var resolved: Dictionary = resolve_target(args, ["indices", "all", "axis", "normal", "near", "radius", "tolerance", "smooth"])
	if not str(resolved.error).is_empty():
		return ToolResult.fail(str(resolved.error))
	
	var result: Dictionary = api_instance.call(
		"inset",
		resolved.model,
		resolved.indices,
		amount,
		bool(p_args.get("individual", false))
	)
	
	return respond_op(p_args, resolved.model, result)
