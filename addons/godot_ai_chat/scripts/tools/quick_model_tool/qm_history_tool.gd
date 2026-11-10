@tool
extends QuickModelToolBase

## 撤销 / 重做（节点自有撤销历史）。


func _init() -> void:
	tool_name = "quick_model_history"
	tool_description = (
		"Undoes or redoes the last modeling step of a QuickModel, using the node's OWN undo history "
		+ "(the editor's Edit > Undo does not apply to QuickModel geometry). "
		+ "action='undo' / 'redo' / 'status' (status only reports availability). "
		+ "Every quick_model_* modeling tool registers one undo step, so this is the way to back out of a wrong operation. "
		+ "Note: history is capped at 100 steps and is cleared when the primitive is switched."
	)


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["undo", "redo", "status"],
				"description": "undo / redo / status (default 'status')."
			},
			"node_path": {
				"type": "string",
				"description": "Path of the QuickModel node. Omit to use the one selected in the editor."
			},
			"save": {
				"type": "boolean",
				"description": "Save the scene after undo/redo. Default false."
			}
		}
	}


func execute(p_args: Dictionary) -> ToolResult:
	var api_instance: Object = api()
	if api_instance == null:
		return ToolResult.fail(missing_plugin_error())
	
	var action: String = text_of(p_args, "action", "status").to_lower()
	
	var resolved: Dictionary = resolve_model(p_args)
	if resolved.model == null:
		return ToolResult.fail(str(resolved.error))
	
	var model: Node = resolved.model
	
	match action:
		"undo":
			return respond_op(p_args, model, api_instance.call("undo", model))
		"redo":
			return respond_op(p_args, model, api_instance.call("redo", model))
		"status":
			var info: Dictionary = api_instance.call("describe", model)
			if not bool(info.get("ok", true)):
				return ToolResult.fail(str(info.get("error", "Cannot read the QuickModel node.")))
			var root: Node = get_active_scene_root()
			if root != null:
				info["node_path"] = node_path_of(root, model)
			return respond(p_args, info, false)
		_:
			return ToolResult.fail("'action' must be undo, redo or status.")
