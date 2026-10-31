@tool
extends Window

## 文本查看窗口（原生独立窗口）
##
## 用于消息块的「Popout」：在独立的系统窗口中查看代码块全文或工具调用的完整参数。
##
## [为什么必须 force_native] 插件 UI 挂在 EditorDock 里，位于编辑器主视口内，而编辑器主窗口
## 开启了 gui_embed_subwindows。因此任何 Window 子类（含 AcceptDialog）都会被当作内嵌子窗口，
## 画在编辑器视口里 —— 既不是独立窗口，也会与编辑器界面互相遮挡。force_native 是让引擎
## 忽略父视口与项目设置、直接使用系统原生窗口的唯一开关。
##
## [只设 force_native 不够] 原生窗口有一组必须配套处理的细节：
## 1. force_native 只允许在窗口未显示时修改 → _init() 先 visible = false 再设标志位；
## 2. 原生子窗口首次呈现时不绘制内容（只显示底色）→ 必须跨帧做一次 1 像素尺寸往返；
## 3. Window 不是容器，程序化改 size 不会重排子控件 → _update_content_layout() 显式同步；
## 4. 原生窗口是独立 Viewport，主题不会继承编辑器主题 → 显式指定并自铺背景；
## 5. 原生窗口没有 OK 按钮，也没有 Esc 默认行为 → 标题栏关闭 / Close 按钮 / Esc 三处统一处理。


# --- Constants ---

## 预加载代码高亮主题
const SYNTAX_HIGHLIGHTER_RES: CodeHighlighter = preload(PluginPaths.CODE_HIGHLIGHT_THEME)

## 初始窗口尺寸（仅首次打开时使用，之后沿用用户调整过的尺寸）
const WINDOW_SIZE: Vector2i = Vector2i(1000, 800)
## 窗口最小尺寸
const MIN_WINDOW_SIZE: Vector2i = Vector2i(600, 400)
## 初始尺寸相对参考窗口（编辑器主窗口）的内缩像素：小屏幕上避免窗口比编辑器还大
const REFERENCE_SIZE_MARGIN: int = 120
## 内容区四周留白（像素），由 PanelContainer 的 stylebox 内容边距提供
const CONTENT_MARGIN: int = 8
## 顶部工具条与内容区之间的间隔
const HEADER_SEPARATION: int = 6
## 编辑器主题不可用时的兜底背景色
const FALLBACK_BG_COLOR: Color = Color(0.12, 0.13, 0.16)
## 代码视图标题
const TITLE_CODE: String = "Code"
## 工具参数视图标题
const TITLE_ARGS: String = "Tool Arguments"


# --- Private Vars ---

# 铺满窗口的内容根节点
var _panel: PanelContainer = null
# 顶部工具条左侧的说明文字
var _title_label: Label = null
# 工具参数视图：纯 TextEdit —— 无高亮器、无行号槽、无任何逐行装饰
var _args_edit: TextEdit = null
# 代码视图：CodeEdit —— 保留语法高亮与行号
var _code_edit: CodeEdit = null
# 首次呈现刷新时使用的目标尺寸
var _refresh_target_size: Vector2i = Vector2i.ZERO


# --- Built-in Functions ---

func _init() -> void:
	# [顺序不能变] Window 的 visible 默认为 true，而 force_native 只允许在窗口未显示时修改，
	# 所以必须先隐藏，等内容就绪后由 show_content() 统一显示。
	visible = false
	force_native = true
	title = TITLE_CODE
	min_size = MIN_WINDOW_SIZE
	# 原生窗口没有 OK 按钮，标题栏关闭请求需要自己接
	close_requested.connect(_on_close_requested)
	# Window 不是容器：窗口尺寸变化不会自动重排子控件，需要手动同步
	size_changed.connect(_update_content_layout)
	
	# 原生窗口是独立 Viewport，主题不会自动继承编辑器主题，控件会退回默认皮肤
	if Engine.is_editor_hint():
		theme = EditorInterface.get_editor_theme()
	
	add_child(_build_ui())


func _unhandled_key_input(p_event: InputEvent) -> void:
	# 原生窗口没有内置的「取消键」行为，Esc 自己接
	var key_event: InputEventKey = p_event as InputEventKey
	if key_event == null or not key_event.pressed or key_event.echo:
		return
	if key_event.keycode != KEY_ESCAPE:
		return
	
	get_viewport().set_input_as_handled()
	_on_close_requested()


# --- Public Functions ---

## 显示内容并呈现窗口（窗口实例由调用方复用或新建）
## [param p_text]: 待显示文本（完整内容，不做截断）
## [param p_is_code_view]: true = 代码视图（语法高亮 + 行号）；false = 工具参数视图（纯文本）
func show_content(p_text: String, p_is_code_view: bool) -> void:
	var view_title: String = TITLE_CODE if p_is_code_view else TITLE_ARGS
	title = view_title
	_title_label.text = view_title
	
	# 两种用途用两个控件表达，而不是靠开关一堆属性：
	# 参数视图在结构上就没有高亮器与行号槽，也就不可能被后续改动"顺手打开"而回归性能。
	_code_edit.visible = p_is_code_view
	_args_edit.visible = not p_is_code_view
	if p_is_code_view:
		_code_edit.text = p_text
	else:
		_args_edit.text = p_text
	
	# 窗口已开着时又点了 Popout：只换内容，不重置用户调好的尺寸与位置
	if visible:
		grab_focus()
		return
	
	_apply_initial_geometry()
	show()
	grab_focus()
	_refresh_after_show()


# --- Private Functions ---

# 构建窗口内容：说明文字 + Close 按钮 + 两个视图控件
func _build_ui() -> Control:
	_panel = PanelContainer.new()
	
	# 原生窗口没有内嵌窗口的 embedded_border 样式兜底，背景必须自己铺，
	# 否则内容区会露出系统/视口的默认色。
	var panel_style: StyleBoxFlat = StyleBoxFlat.new()
	panel_style.bg_color = _get_editor_bg_color()
	panel_style.set_content_margin_all(CONTENT_MARGIN)
	_panel.add_theme_stylebox_override("panel", panel_style)
	
	var vbox: VBoxContainer = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", HEADER_SEPARATION)
	_panel.add_child(vbox)
	
	var header: HBoxContainer = HBoxContainer.new()
	
	_title_label = Label.new()
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_CHAR
	_title_label.modulate = Color(0.7, 0.7, 0.7)
	header.add_child(_title_label)
	
	var close_button: Button = Button.new()
	close_button.text = "Close"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(_on_close_requested)
	header.add_child(close_button)
	
	vbox.add_child(header)
	
	# 1. 工具参数视图：只设必要项，其余沿用 TextEdit 默认值 ——
	#    高亮器默认 null、没有行号槽、draw_tabs / draw_spaces / minimap_draw 默认全为 false。
	#    wrap 固定 NONE：这是 TextEdit 最省的模式（可见行数 == 逻辑行数，无需逐行换行测量），
	#    参数文本已按真实换行渲染，本就不需要换行。
	_args_edit = TextEdit.new()
	_args_edit.editable = false
	_args_edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_args_edit.caret_blink = false
	_args_edit.highlight_current_line = false
	_args_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_args_edit)
	
	# 2. 代码视图：保留语法高亮与行号（与内联代码块一致）
	_code_edit = CodeEdit.new()
	_code_edit.editable = false
	_code_edit.syntax_highlighter = SYNTAX_HIGHLIGHTER_RES
	_code_edit.gutters_draw_line_numbers = true
	_code_edit.draw_tabs = true
	_code_edit.minimap_draw = false
	_code_edit.wrap_mode = CodeEdit.LINE_WRAPPING_NONE
	# 平滑滚动是"逐帧重绘新露出区域"的持续成本，对查看器不划算
	_code_edit.scroll_smooth = false
	_code_edit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(_code_edit)
	
	return _panel


# 让内容根节点铺满整个窗口（窗口尺寸变化时同步刷新）
func _update_content_layout() -> void:
	if not is_instance_valid(_panel):
		return
	
	_panel.position = Vector2.ZERO
	_panel.size = Vector2(size)


# 计算并应用首次呈现的尺寸与位置
func _apply_initial_geometry() -> void:
	var target_size: Vector2i = _fit_to_reference(WINDOW_SIZE)
	min_size = Vector2i(mini(MIN_WINDOW_SIZE.x, target_size.x), mini(MIN_WINDOW_SIZE.y, target_size.y))
	size = target_size
	
	var reference_window: Window = _reference_window()
	if reference_window == null:
		move_to_center()
		return
	
	# 居中于编辑器主窗口：initial_position 默认为 WINDOW_INITIAL_POSITION_ABSOLUTE，
	# 因此 position 就是屏幕绝对坐标。
	position = reference_window.position + (reference_window.size - target_size) / 2


# 把目标尺寸收敛到参考窗口能容纳的范围（避免小屏幕上窗口顶出屏幕外）
func _fit_to_reference(p_size: Vector2i) -> Vector2i:
	var reference_window: Window = _reference_window()
	if reference_window == null:
		return p_size
	
	var margin: Vector2i = Vector2i(REFERENCE_SIZE_MARGIN, REFERENCE_SIZE_MARGIN)
	var limit: Vector2i = (reference_window.size - margin).max(MIN_WINDOW_SIZE)
	return p_size.clamp(MIN_WINDOW_SIZE, limit)


# 原生子窗口首次呈现时不会绘制自身内容（表现为只显示窗口底色），
# 必须在「窗口已显示之后」再经历一次真实的尺寸变更才会刷新。
# 注意：必须跨帧 —— 同一帧内与窗口创建/显示合并的尺寸变更不生效。
# 这里在首帧之后做一次 1 像素的尺寸往返，等价于自动帮用户拖拽一下窗口边缘。
# [为什么用信号而不是 await] await 版本在窗口两帧之间被销毁时，
# 协程恢复会报 "class instance is gone"；信号连接会随对象销毁自动断开，不留残留错误。
func _refresh_after_show() -> void:
	_refresh_target_size = size
	if not is_inside_tree():
		return
	
	get_tree().process_frame.connect(_on_refresh_grow, CONNECT_ONE_SHOT)


# 首次呈现刷新：放大 1 像素
func _on_refresh_grow() -> void:
	size = _refresh_target_size + Vector2i(1, 1)
	_update_content_layout()
	get_tree().process_frame.connect(_on_refresh_restore, CONNECT_ONE_SHOT)


# 首次呈现刷新：恢复目标尺寸
func _on_refresh_restore() -> void:
	size = _refresh_target_size
	_update_content_layout()


# 取编辑器背景色；取不到时用兜底色
func _get_editor_bg_color() -> Color:
	if Engine.is_editor_hint():
		var editor_theme: Theme = EditorInterface.get_editor_theme()
		if editor_theme != null and editor_theme.has_color("dark_color_2", "Editor"):
			return editor_theme.get_color("dark_color_2", "Editor")
	
	return FALLBACK_BG_COLOR


# 参考窗口（编辑器主窗口）：用于计算初始尺寸与居中位置
func _reference_window() -> Window:
	var parent_node: Node = get_parent()
	if parent_node == null:
		return null
	
	var parent_window: Window = parent_node.get_window()
	if parent_window == null or parent_window == self:
		return null
	
	return parent_window


# --- Signal Callbacks ---

# 关闭请求（标题栏 ✕ / Close 按钮 / Esc）统一入口：直接销毁
# [为什么销毁而不是隐藏] 隐藏只省掉"重建节点"的开销，却把 Window 节点、Viewport 结构、
# 四个空控件以及本窗口持有的编辑器 Theme 引用全部留下。其中 Theme 引用会随编辑器
# 主题切换累积（编辑器每次重建主题都是新实例，隐藏窗口攥着旧的那份），是唯一会缓慢
# 增长的部分。而查看窗口是低频操作，重建成本（含首次呈现的 1px 刷新）肉眼无感。
func _on_close_requested() -> void:
	queue_free()
