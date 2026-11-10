@tool
extends QuickModelToolBase

## 顶点级整体变换（移动 / 旋转 / 缩放），枢轴 = 受影响顶点的形心。

## 本工具不接受 axis 作为筛选条件（axis 在此表示旋转轴）。
const TRANSFORM_FILTER_KEYS: Array[String] = ["indices", "all", "normal", "near", "radius", "tolerance"]


func _init() -> void:
	tool_name = "quick_model_transform"
	tool_description = (
		"Moves, rotates or scales a QuickModel's geometry (vertex level, pivot = centroid of the affected vertices). "
		+ "Target components are given by 'mode' + predicate (all / axis-free filters / indices); with no predicate the "
		+ "node's current selection is used. kind='move' with vector [x,y,z]; kind='scale' with vector as per-axis factors "
		+ "([2,1,1] stretches twice on X); kind='rotate' with angle_degrees + axis, e.g. axis '+y'. "
		+ "To move the whole node in the scene instead of its vertices, use the scene node tools."
	)


func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"node_path": {
				"type": "string",
				"description": "Path of the QuickModel node. Omit to use the one selected in the editor."
			},
			"kind": {
				"type": "string",
				"enum": ["move", "rotate", "scale"],
				"description": "Transform kind. Required."
			},
			"vector": {
				"type": "array",
				"items": { "type": "number" },
				"description": "move: translation [x,y,z] (local units). scale: per-axis factors [x,y,z]. Rotation ignores it."
			},
			"angle_degrees": {
				"type": "number",
				"description": "Rotation angle in degrees (rotate only). Required for kind='rotate'."
			},
			"axis": {
				"type": "string",
				"description": "Rotation axis: '+y' (default), '-y', '+x', '+z', 'up', 'forward'. Rotate only."
			},
			"mode": {
				"type": "string",
				"enum": ["vertex", "edge", "face"],
				"description": "Which components the predicate applies to (their vertices get transformed). Default: node's current mode."
			},
			"indices": {
				"type": "array",
				"items": { "type": "integer" },
				"description": "Explicit component indices (interpreted in 'mode')."
			},
			"all": {
				"type": "boolean",
				"description": "Transform every component of the mode (i.e. usually the whole model)."
			},
			"normal": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Only transform components whose face normal matches this direction [x,y,z]."
			},
			"near": {
				"type": "array",
				"items": { "type": "number" },
				"description": "Only transform components whose center is within 'radius' of this local point [x,y,z]."
			},
			"radius": {
				"type": "number",
				"description": "Radius for 'near'."
			},
			"tolerance": {
				"type": "number",
				"description": "Angle tolerance in degrees for 'normal'. Default 20."
			},
			"save": {
				"type": "boolean",
				"description": "Save the scene after the change. Default false."
			}
		},
		"required": ["kind"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var api_instance: Object = api()
	if api_instance == null:
		return ToolResult.fail(missing_plugin_error())
	
	var kind: String = text_of(p_args, "kind").to_lower()
	if not (kind in ["move", "rotate", "scale"]):
		return ToolResult.fail("'kind' must be move, rotate or scale.")
	
	var resolved: Dictionary = resolve_target(p_args, TRANSFORM_FILTER_KEYS)
	if resolved.model == null:
		return ToolResult.fail(str(resolved.error))
	
	var value: Variant = null
	
	match kind:
		"move", "scale":
			var vector: Vector3 = vec3_of(p_args.get("vector", []))
			if vector.is_zero_approx():
				return ToolResult.fail("'vector' [x,y,z] is required and must be non-zero for %s." % kind)
			value = vector
		"rotate":
			var axis_text: String = text_of(p_args, "axis", "+y")
			var axis: Vector3 = _axis_from_text(axis_text)
			if axis.is_zero_approx():
				axis = Vector3.UP
			var degrees: float = float(p_args.get("angle_degrees", 0.0))
			if is_zero_approx(degrees):
				return ToolResult.fail("'angle_degrees' is required and must be non-zero for rotate.")
			value = {"axis": axis, "degrees": degrees}
	
	var result: Dictionary = api_instance.call(
		"transform_components",
		resolved.model,
		int(resolved.mode),
		resolved.indices,
		kind,
		value,
		false
	)
	
	return respond_op(p_args, resolved.model, result)


# 方向文本 → 单位向量（"+y" / "up" / "-x" …）。
func _axis_from_text(p_text: String) -> Vector3:
	var text: String = p_text.strip_edges().to_lower()
	if text.is_empty():
		return Vector3.ZERO
	
	var sign_value: float = -1.0 if text.begins_with("-") else 1.0
	var axis: String = text.trim_prefix("-").trim_prefix("+").strip_edges()
	
	match axis:
		"x", "right":
			return Vector3(sign_value, 0.0, 0.0)
		"y", "up":
			return Vector3(0.0, sign_value, 0.0)
		"z", "back":
			return Vector3(0.0, 0.0, sign_value)
		"left":
			return Vector3(-sign_value, 0.0, 0.0)
		"down":
			return Vector3(0.0, -sign_value, 0.0)
		"forward", "front":
			return Vector3(0.0, 0.0, -sign_value)
	
	return Vector3.ZERO
