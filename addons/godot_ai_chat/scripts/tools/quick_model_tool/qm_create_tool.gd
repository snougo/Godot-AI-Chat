@tool
extends QuickModelToolBase

## 新建 QuickModel 节点，或把已有节点切换成另一种基础图元。


func _init() -> void:
	tool_name = "quick_model_create"
	tool_description = (
		"Creates a QuickModel node in the edited scene, or switches an existing QuickModel to another base primitive. "
		+ "QuickModel is the editor's built-in polygon modeling node; it starts from a primitive and is then reshaped "
		+ "with extrude / inset / bevel / loop cut / transform. "
		+ "operation='create': adds a node (primitive, name, position, scale). "
		+ "operation='set_primitive': rebuilds an existing node's mesh from a primitive — THIS DISCARDS its geometry "
		+ "and undo history, so only use it on a freshly created model."
	)


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"operation": {
				"type": "string",
				"enum": ["create", "set_primitive"],
				"description": "create (default): add a new node. set_primitive: rebuild an existing node's mesh."
			},
			"node_path": {
				"type": "string",
				"description": "Target node for set_primitive. Omit to use the QuickModel selected in the editor."
			},
			"primitive": {
				"type": "string",
				"enum": ["cube", "plane", "circle", "uv_sphere", "cylinder"],
				"description": "Base primitive. Default 'cube'. Base sizes: cube 1x1x1, plane 2x2 (XZ), circle/sphere/cylinder diameter 1."
			},
			"name": {
				"type": "string",
				"description": "Node name for create. Auto-uniquified if taken. Default 'QuickModel'."
			},
			"parent_path": {
				"type": "string",
				"description": "Parent node path for create. Default '.' (scene root)."
			},
			"position": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Node position [x,y,z] for create. Default [0,0,0]."
			},
			"scale": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Vertex scale factor [x,y,z] applied after creation, e.g. [2,1,2.5] turns the unit cube into a 2x1x2.5 box. Default [1,1,1] (no change)."
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
	
	var operation: String = text_of(p_args, "operation", "create").to_lower()
	
	match operation:
		"create":
			return _create(p_args, api_instance)
		"set_primitive":
			return _set_primitive(p_args, api_instance)
		_:
			return ToolResult.fail("Unknown operation '%s'. Use create or set_primitive." % operation)


# --- Private Functions ---

func _create(p_args: Dictionary, p_api: Object) -> ToolResult:
	var root: Node = get_active_scene_root()
	if root == null:
		return ToolResult.fail("No active scene in the editor.")
	
	var parent_result: Dictionary = resolve_node(root, text_of(p_args, "parent_path", "."))
	if parent_result.node == null:
		return ToolResult.fail(str(parent_result.error))
	
	var parent: Node = parent_result.node
	var blocker: Node = instance_owner_of(root, parent)
	if blocker != null:
		return ToolResult.fail(
			"'%s' is an internal node of the instanced scene '%s' — nodes added there are dropped on save. "
			+ "Open that scene and create the model inside it." % [node_path_of(root, parent), blocker.scene_file_path]
		)
	
	if not ResourceLoader.exists(MODEL_SCRIPT_PATH):
		return ToolResult.fail("Quick Model plugin not found (%s)." % MODEL_SCRIPT_PATH)
	
	var primitive_text: String = text_of(p_args, "primitive", "cube").to_lower()
	var primitive_kind: int = int(p_api.call("primitive_from_name", primitive_text))
	if primitive_kind < 0:
		return ToolResult.fail("Unknown primitive '%s'. Use cube, plane, circle, uv_sphere or cylinder." % primitive_text)
	
	var node_script: Script = load(MODEL_SCRIPT_PATH)
	var model: Node = node_script.new()
	
	var wanted: String = text_of(p_args, "name", "QuickModel").validate_node_name()
	if wanted.is_empty():
		wanted = "QuickModel"
	if has_child_named(parent, wanted):
		wanted = unique_child_name(parent, wanted)
	model.name = wanted
	
	# primitive 必须在入树**之前**设置：节点入树时按 primitive 生成网格，
	# 入树后再设会触发一次重建（清空选择与撤销历史）。
	model.set("primitive", primitive_kind)
	
	var position_value: Vector3 = vec3_of(p_args.get("position", []))
	
	var undo_redo: EditorUndoRedoManager = EditorInterface.get_editor_undo_redo()
	undo_redo.create_action("AI Create QuickModel %s" % wanted)
	undo_redo.add_do_method(parent, "add_child", model)
	undo_redo.add_do_property(model, "owner", root)
	undo_redo.add_do_property(model, "position", position_value)
	undo_redo.add_undo_method(parent, "remove_child", model)
	undo_redo.add_do_reference(model)
	undo_redo.commit_action()
	
	var data: Dictionary = {
		"ok": true,
		"op": "create",
		"node_path": node_path_of(root, model),
		"name": wanted,
		"primitive": primitive_text,
		"position": [snappedf(position_value.x, 0.0001), snappedf(position_value.y, 0.0001), snappedf(position_value.z, 0.0001)],
	}
	
	_apply_scale(data, model, p_args, p_api)
	var info: Dictionary = p_api.call("describe", model)
	data["counts"] = info.get("counts", {})
	
	return respond(p_args, data)


func _set_primitive(p_args: Dictionary, p_api: Object) -> ToolResult:
	var resolved: Dictionary = resolve_model(p_args)
	if resolved.model == null:
		return ToolResult.fail(str(resolved.error))
	
	var model: Node = resolved.model
	var primitive_text: String = text_of(p_args, "primitive").to_lower()
	if primitive_text.is_empty():
		return ToolResult.fail("'primitive' is required for set_primitive.")
	
	var primitive_kind: int = int(p_api.call("primitive_from_name", primitive_text))
	if primitive_kind < 0:
		return ToolResult.fail("Unknown primitive '%s'. Use cube, plane, circle, uv_sphere or cylinder." % primitive_text)
	
	# setter 内部会重建网格并清空选择与撤销历史（不可恢复）
	model.set("primitive", primitive_kind)
	
	var root: Node = get_active_scene_root()
	var data: Dictionary = {
		"ok": true,
		"op": "set_primitive",
		"node_path": node_path_of(root, model) if root != null else "",
		"primitive": primitive_text,
	}
	
	_apply_scale(data, model, p_args, p_api)
	var info: Dictionary = p_api.call("describe", model)
	data["counts"] = info.get("counts", {})
	
	return respond(p_args, data)


# 可选的整体缩放（顶点级，走 TransformOperation 增量快照，可撤销）。
func _apply_scale(p_data: Dictionary, p_model: Node, p_args: Dictionary, p_api: Object) -> void:
	var factor: Vector3 = vec3_of(p_args.get("scale", []))
	if factor.is_zero_approx() or factor.is_equal_approx(Vector3.ONE):
		return
	
	var scaled: Dictionary = p_api.call("transform_all", p_model, "scale", factor)
	if not bool(scaled.get("ok", false)):
		p_data["scale_error"] = str(scaled.get("message", ""))
		return
	
	p_data["scale"] = [snappedf(factor.x, 0.0001), snappedf(factor.y, 0.0001), snappedf(factor.z, 0.0001)]
