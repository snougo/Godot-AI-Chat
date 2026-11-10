@tool
extends QuickModelToolBase

## 填充（Fill）：把选中的顶点 / 边围成的闭环或开链补成一个面。


func _init() -> void:
	tool_name = "quick_model_fill"
	tool_description = (
		"Fills a hole in a QuickModel by closing a selected vertex ring or edge chain into a single face. "
		+ "Vertex mode uses the mesh edges between the selected vertices; edge mode uses the selected edges directly. "
		+ "The ring order and winding come from topology, not from geometry, so concave boundaries work too. "
		+ "Open chains are closed with an implied missing edge (e.g. 3 edges of a quad -> that quad). "
		+ "The new face stays selected."
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
				"enum": ["vertex", "edge"],
				"description": "Fill from selected vertices (default: the node's current mode) or from selected edges."
			},
			"indices": {
				"type": "array",
				"items": { "type": "integer" },
				"description": "Explicit vertex/edge indices."
			},
			"all": {
				"type": "boolean",
				"description": "Use every vertex/edge of the mode (rarely useful for fill)."
			},
			"axis": {
				"type": "string",
				"description": "Predicate: only components whose adjacent face normal matches this direction, e.g. '+y'."
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
			"boundary": {
				"type": "boolean",
				"description": "Edge mode: only boundary edges (exactly one adjacent face) — usually what you want for filling a hole."
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
	
	if int(resolved.mode) == int(api_instance.call("mode_from_name", "face")):
		return ToolResult.fail("Fill works in vertex or edge mode only — pass mode='vertex' or mode='edge'.")
	
	var result: Dictionary = api_instance.call("fill", resolved.model, int(resolved.mode), resolved.indices)
	
	return respond_op(p_args, resolved.model, result)
