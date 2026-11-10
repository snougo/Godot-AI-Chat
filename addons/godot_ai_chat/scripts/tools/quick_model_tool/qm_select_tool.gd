@tool
extends QuickModelToolBase

## 按索引或几何谓词选择顶点 / 边 / 面（写入节点选择，不改几何）。


func _init() -> void:
	tool_name = "quick_model_select"
	tool_description = (
		"Selects components (vertices / edges / faces) of a QuickModel node by index list or by geometric predicate. "
		+ "Predicates: axis/normal (by face normal direction), near+radius (by element center position), "
		+ "boundary (edges with one adjacent face only), smooth (faces that are smooth-shaded), all (everything). "
		+ "This only changes the selection — geometry is untouched. "
		+ "Most modeling tools accept the same predicate parameters directly, so use this mainly to inspect "
		+ "what a predicate picks, or to build up a selection step by step."
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
				"description": "Component mode to select in. Default: the node's current mode."
			},
			"indices": {
				"type": "array",
				"items": { "type": "integer" },
				"description": "Explicit component indices. Out-of-range indices are rejected. Ignored other predicates when given."
			},
			"all": {
				"type": "boolean",
				"description": "Select every component of the mode (can be combined with other predicates to filter the whole set)."
			},
			"axis": {
				"type": "string",
				"description": "Direction predicate, e.g. '+y' (up-facing faces), '-x', 'up', 'forward'. Matched against face normals."
			},
			"normal": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Custom direction predicate [x,y,z], matched against face normals."
			},
			"tolerance": {
				"type": "number",
				"description": "Angle tolerance in degrees for axis/normal matching. Default 20."
			},
			"near": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Position predicate [x,y,z] in the node's LOCAL space, matched against face centers / edge midpoints / vertex positions."
			},
			"radius": {
				"type": "number",
				"description": "Radius for the 'near' predicate (required together with 'near')."
			},
			"boundary": {
				"type": "boolean",
				"description": "Edge mode only: keep only boundary edges (exactly one adjacent face)."
			},
			"smooth": {
				"type": "boolean",
				"description": "Face mode only: true = smooth-shaded faces, false = flat-shaded faces."
			}
		}
	}


func execute(p_args: Dictionary) -> ToolResult:
	var api_instance: Object = api()
	if api_instance == null:
		return ToolResult.fail(missing_plugin_error())
	
	var resolved: Dictionary = resolve_model(p_args)
	if resolved.model == null:
		return ToolResult.fail(str(resolved.error))
	
	var model: Node = resolved.model
	var mode: int = mode_of(p_args, model)
	if mode < 0:
		return ToolResult.fail("Unknown 'mode'. Use vertex, edge or face.")
	
	var filter: Dictionary = filter_of(p_args)
	if filter.is_empty():
		return ToolResult.fail(
			"Nothing to select: pass 'indices', 'all': true, or at least one predicate "
			+ "(axis / normal / near+radius / boundary / smooth)."
		)
	
	var picked: Dictionary = api_instance.call("resolve_indices", model, mode, filter)
	if not str(picked["error"]).is_empty():
		return ToolResult.fail(str(picked["error"]))
	
	var indices: PackedInt32Array = picked["indices"]
	api_instance.call("apply_selection", model, mode, indices)
	
	var report: Array = []
	for position: int in mini(indices.size(), 200):
		report.append(int(indices[position]))
	
	var root: Node = get_active_scene_root()
	var data: Dictionary = {
		"ok": true,
		"mode": api_instance.call("mode_name", mode),
		"selected_count": indices.size(),
		"selected": report,
		"truncated": indices.size() > report.size(),
		"counts": api_instance.call("describe", model).get("counts", {}),
	}
	
	if root != null:
		data["node_path"] = node_path_of(root, model)
	
	return respond(p_args, data, false)
