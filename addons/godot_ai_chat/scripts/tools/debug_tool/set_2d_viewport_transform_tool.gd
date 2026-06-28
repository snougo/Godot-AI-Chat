@tool
extends AiTool

## 设置 2D 编辑器视窗的视图变换
## 
## 控制 2D 编辑器视口的缩放（zoom）和平移（pan），
## 让 Agent 能放大观察细节或平移检查场景不同区域。

# --- Built-in Functions ---

func _init() -> void:
	tool_name = "set_2d_viewport_transform"
	tool_description = "Controls the 2D editor viewport transform. Supports zoom (scale factor) and pan offset."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"zoom": {
				"type": "number",
				"description": "Zoom level. Values > 1 zoom in, < 1 zoom out. For example: 2.0 = 2x zoom, 0.5 = half zoom. Optional."
			},
			"pan_offset": {
				"type": "array",
				"description": "Pan offset as [x, y] in pixels. Positive x pans right, positive y pans down. Optional.",
				"items": {"type": "number"}
			}
		},
		"required": []
	}


func execute(p_args: Dictionary) -> ToolResult:
	if not Engine.is_editor_hint():
		return ToolResult.fail("Error: editor only tool.")
	
	EditorInterface.set_main_screen_editor("2D")
	var viewport: SubViewport = EditorInterface.get_editor_viewport_2d()
	if not viewport:
		return ToolResult.fail("Error: no 2D viewport available.")
	
	var xform: Transform2D = viewport.global_canvas_transform
	var changes: Array[String] = []
	
	# 1. 设置缩放
	if p_args.has("zoom") and not p_args["zoom"] == null:
		var zoom_val: float = float(p_args["zoom"])
		if zoom_val <= 0:
			return ToolResult.fail("Error: zoom must be positive, got %f." % zoom_val)
		
		# 以当前缩放为基准，计算新的缩放变换
		var current_scale: Vector2 = xform.get_scale()
		var scale_ratio := Vector2(zoom_val, zoom_val) / current_scale
		xform = xform.scaled(scale_ratio)
		changes.append("zoom → %.2fx" % zoom_val)
	
	# 2. 设置平移
	if p_args.has("pan_offset") and not p_args["pan_offset"] == null:
		var pan: Array = p_args["pan_offset"]
		if pan.size() < 2:
			return ToolResult.fail("Error: pan_offset requires 2 values [x, y], got %d." % pan.size())
		xform.origin = Vector2(float(pan[0]), float(pan[1]))
		changes.append("pan → (%.0f, %.0f)" % [float(pan[0]), float(pan[1])])
	
	if changes.is_empty():
		var current_scale: Vector2 = xform.get_scale()
		return ToolResult.ok("No parameters provided. Transform unchanged. Current zoom: (%.2fx, %.2fx), pan: %s" % [current_scale.x, current_scale.y, str(xform.origin)])
	
	viewport.global_canvas_transform = xform
	return ToolResult.ok("2D viewport transform updated: %s" % ", ".join(changes))
