@tool
extends BaseSceneTool

## 捕获场景视窗截图工具
## 
## 捕获当前编辑器3D或2D视窗的画面，返回截图数据供AI分析。
## 自动检测当前活动的视窗类型（3D优先），对于AI理解场景布局、节点位置、视觉效果等非常有用。

# --- Built-in Functions ---

func _init() -> void:
	tool_name = "capture_edited_scene_screenshot"
	tool_description = "Captures a screenshot of the current edited scene viewport in the Godot Editor. Useful for analyzing scene layout, visual effects, or debugging rendering issues. Returns the screenshot as an image attachment."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {},
		"required": []
	}


func execute(_p_args: Dictionary) -> Dictionary:
	if not Engine.is_editor_hint():
		return {"success": false, "data": "Editor only tool."}
	
	# 获取当前编辑的场景根节点
	var root: Node = get_active_scene_root()
	if not root:
		return {"success": false, "data": "No active scene in editor."}
	
	var viewport: SubViewport = null
	var viewport_type: String = ""
	
	# 优先尝试获取3D视窗
	var viewport_3d: SubViewport = EditorInterface.get_editor_viewport_3d()
	if viewport_3d:
		viewport = viewport_3d
		viewport_type = "3D"
	
	# 如果没有3D视窗，尝试获取2D视窗
	if not viewport:
		var viewport_2d: SubViewport = EditorInterface.get_editor_viewport_2d()
		if viewport_2d:
			viewport = viewport_2d
			viewport_type = "2D"
	
	# 如果都没有获取到
	if not viewport:
		return {"success": false, "data": "No 2D or 3D viewport available."}
	
	# 等待渲染完成
	await RenderingServer.frame_post_draw
	
	# 获取视窗纹理并转换为图像
	var viewport_texture: ViewportTexture = viewport.get_texture()
	var image: Image = viewport_texture.get_image()
	
	# 获取实际尺寸
	var width: int = image.get_width()
	var height: int = image.get_height()
	
	# 将图像编码为 PNG
	var png_buffer: PackedByteArray = image.save_png_to_buffer()
	
	return {
		"success": true,
		"data": "Viewport screenshot captured successfully. Type: %s, Resolution: %dx%d. The image is attached to this message." % [viewport_type, width, height],
		"attachments": {
			"image_data": png_buffer,
			"mime": "image/png"
		}
	}
