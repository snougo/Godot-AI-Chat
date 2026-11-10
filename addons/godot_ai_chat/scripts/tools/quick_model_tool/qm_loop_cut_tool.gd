@tool
extends QuickModelToolBase

## 环切（Loop Cut）：沿边环线（互相平行的边集合）插一圈切点。


func _init() -> void:
	tool_name = "quick_model_loop_cut"
	tool_description = (
		"Cuts a loop of edges into a QuickModel: from one edge the plugin walks the parallel edge ring "
		+ "(Blender's Ctrl+Alt+click ring) and inserts cut points at 'ratio' along every ring edge, splitting the faces "
		+ "that carry them. Get a valid edge index from quick_model_inspect (what='edges'). "
		+ "Set expand_ring=false to cut only the single given edge. "
		+ "On non-quad topology the result degrades gracefully (a face with one cut edge just gets a vertex inserted)."
	)


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Path of the QuickModel node. Omit to use the one selected in the editor."
			},
			"edge_index": {
				"type": "integer",
				"minimum": 0,
				"description": "Edge index to start from (any edge of the ring). Required."
			},
			"ratio": {
				"type": "number",
				"description": "Position along each ring edge, 0..1 (0.5 = middle). Default 0.5."
			},
			"expand_ring": {
				"type": "boolean",
				"description": "true (default) = cut the whole parallel edge ring; false = cut only edge_index."
			},
			"save": {
				"type": "boolean",
				"description": "Save the scene after the change. Default false."
			}
		},
		"required": ["edge_index"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var api_instance: Object = api()
	if api_instance == null:
		return ToolResult.fail(missing_plugin_error())
	
	if not p_args.has("edge_index"):
		return ToolResult.fail("'edge_index' is required. Read valid indices with quick_model_inspect (what='edges').")
	
	var resolved: Dictionary = resolve_model(p_args)
	if resolved.model == null:
		return ToolResult.fail(str(resolved.error))
	
	var ratio: float = clampf(float(p_args.get("ratio", 0.5)), 0.001, 0.999)
	
	var result: Dictionary = api_instance.call(
		"loop_cut",
		resolved.model,
		int(p_args.get("edge_index", -1)),
		ratio,
		bool(p_args.get("expand_ring", true))
	)
	
	return respond_op(p_args, resolved.model, result)
