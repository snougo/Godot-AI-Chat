@tool
extends QuickModelToolBase

## 读取 QuickModel 网格信息（只读，不改数据）。


func _init() -> void:
	tool_name = "quick_model_inspect"
	tool_description = (
		"Reads a QuickModel node (the Godot editor's built-in point/edge/face modeling node): "
		+ "element counts, bounding box, current component mode and selection, plus paged lists of "
		+ "faces / edges / vertices with their indices, centers and normals. "
		+ "Call this BEFORE any mesh operation: it tells you which indices exist, how big the mesh is, "
		+ "and where each face/edge sits in space (local coordinates). "
		+ "Read-only — nothing is modified."
	)


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Path of the QuickModel node. Omit to use the QuickModel currently selected in the editor (or the only one in the scene)."
			},
			"what": {
				"type": "string",
				"enum": ["overview", "faces", "edges", "vertices"],
				"description": "What to read. 'overview' (default): counts, aabb, mode, selection. 'faces'/'edges'/'vertices': paged element list."
			},
			"offset": {
				"type": "integer",
				"minimum": 0,
				"description": "Paging offset for element lists. Default 0."
			},
			"limit": {
				"type": "integer",
				"minimum": 1,
				"maximum": 256,
				"description": "Maximum number of elements to return. Default 32."
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
	var what: String = text_of(p_args, "what", "overview").to_lower()
	var offset: int = int(p_args.get("offset", 0))
	var limit: int = int(p_args.get("limit", 32))
	
	var data: Dictionary
	
	match what:
		"faces":
			data = api_instance.call("list_faces", model, offset, limit)
		"edges":
			data = api_instance.call("list_edges", model, offset, limit)
		"vertices":
			data = api_instance.call("list_vertices", model, offset, limit)
		_:
			data = api_instance.call("describe", model)
	
	if not bool(data.get("ok", true)):
		return ToolResult.fail(str(data.get("error", "Cannot read the QuickModel node.")))
	
	var root: Node = get_active_scene_root()
	if root != null:
		data["node_path"] = node_path_of(root, model)
	
	return respond(p_args, data, false)
