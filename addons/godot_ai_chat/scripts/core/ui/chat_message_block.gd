@tool
class_name ChatMessageBlock
extends FoldableContainer

## 消息显示块
##
## 负责单条消息的 UI 渲染，支持 Markdown 解析、代码高亮、打字机效果和工具调用展示。
## Markdown 解析逻辑已分离至 MarkdownStreamParser，本类仅负责 UI 渲染。

# --- Constants ---

## 预加载代码高亮主题
const SYNTAX_HIGHLIGHTER_RES: CodeHighlighter = preload(PluginPaths.CODE_HIGHLIGHT_THEME)
## 预加载代码查看器窗口
const CODE_VIEWER_WINDOW_RES: PackedScene = preload("res://addons/godot_ai_chat/scene/popup_code_viewer_window.tscn")

# --- @onready Vars ---

@onready var _content_container: VBoxContainer = $MarginContainer/VBoxContainer
@onready var _main_margin_container: Control = $MarginContainer

# --- Private Vars ---

# Markdown 解析器实例
var _parser: MarkdownStreamParser = MarkdownStreamParser.new()

# 记录上一个创建的 UI 节点，用于连续追加内容
var _last_ui_node: Control = null

# 是否处于流式模式（影响打字机效果的启用）
var _streaming: bool = false

# 打字机状态
var _typing_active: bool = false
# 当前正在执行打字机效果的节点
var _current_typing_node: RichTextLabel = null

# 思考内容 UI 引用
var _reasoning_container: FoldableContainer = null
# [优化P0] 使用 TextEdit 替代 RichTextLabel，自带行级虚拟化，避免超长文本布局阻塞
var _reasoning_label: TextEdit = null
# [优化P1] 思考内容懒加载缓存：折叠时将文本存入缓存并清空 TextEdit，展开时才填充
var _reasoning_text_cache: String = ""

# 消息块是否被挂起
var _is_suspended: bool = false

# 当前打开的代码查看窗口引用
var _current_popup_code_view_window: PopupCodeViewWindow = null


# --- Built-in Functions ---

func _ready() -> void:
	_parser.segment_parsed.connect(_on_parser_segment_parsed)
	if not _content_container:
		# 等待一帧以确保节点就绪 (主要用于 Tool 模式下的实例化)
		await get_tree().process_frame


# --- Public Functions ---

## 设置消息内容（静态加载）
## [param p_role]: 消息角色
## [param p_content]: 消息正文
## [param p_model_name]: 模型名称
## [param p_tool_calls]: 工具调用列表
## [param p_reasoning]: 思考内容
func set_content(p_role: String, p_content: String, p_model_name: String = "", p_tool_calls: Array = [], p_reasoning: String = "") -> void:
	_set_title(p_role, p_model_name)
	_clear_content()

	if not p_reasoning.is_empty():
		append_reasoning(p_reasoning)

	_streaming = false
	_parser.feed(p_content)
	_parser.flush()

	for tc in p_tool_calls:
		show_tool_call(tc)


## 开始流式接收消息
## [param p_role]: 消息角色
## [param p_model_name]: 模型名称
func start_stream(p_role: String, p_model_name: String = "") -> void:
	_set_title(p_role, p_model_name)
	_clear_content()
	_streaming = true
	visible = true


## 追加流式文本块
## [param p_text]: 新增的文本片段
func append_chunk(p_text: String) -> void:
	if p_text.is_empty():
		return
	_parser.feed(p_text)


## 追加流式思考内容
## [param p_text]: 新增的思考内容片段
func append_reasoning(p_text: String) -> void:
	if p_text.is_empty():
		return

	if not is_instance_valid(_reasoning_container):
		_create_reasoning_ui()

	# [优化P1] 折叠状态下仅缓存文本，不更新 UI，避免触发布局计算
	if _reasoning_container.is_folded():
		_reasoning_text_cache += p_text
	elif is_instance_valid(_reasoning_label):
		_reasoning_label.text += p_text


## 结束流式接收，刷新解析器缓冲区
func finish_stream() -> void:
	_parser.flush()
	_finish_typing()


## 设置错误信息显示
## [param p_text]: 错误信息文本
func set_error(p_text: String) -> void:
	title = "❌ Error"
	_clear_content()
	var label: RichTextLabel = _create_text_block(p_text, true)
	label.modulate = Color(1, 0.4, 0.4)


## 获取当前消息的角色
func get_role() -> String:
	return get_meta("role") if has_meta("role") else ""


## 展示工具调用详情
## [param p_tool_call]: 工具调用信息字典
func show_tool_call(p_tool_call: Dictionary) -> void:
	# 提取工具名称
	var tool_name: String = ""
	if p_tool_call.has("function"):
		tool_name = p_tool_call.function.get("name", "unknown")
	else:
		tool_name = p_tool_call.get("name", "unknown")

	# [UI防御] 清洗并验证。如果是非法名称，直接忽略，不生成任何 UI
	var clean_name: String = tool_name.replace("", "").replace("tool_call", "").strip_edges()
	if not ToolBox.is_valid_tool_name(clean_name):
		return

	var call_id: String = p_tool_call.get("id", "no-id")
	var safe_node_name: String = ("Tool_" + call_id).validate_node_name()

	var shown_calls: Array = _content_container.get_meta("shown_calls", [])
	if call_id in shown_calls:
		_update_tool_call_ui(safe_node_name, p_tool_call)
		return

	shown_calls.append(call_id)
	_content_container.set_meta("shown_calls", shown_calls)

	# 1. 创建外观容器
	var panel: PanelContainer = PanelContainer.new()
	panel.name = safe_node_name

	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.13, 0.16, 0.9)
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	style.border_width_left = 4
	style.border_color = Color.GOLD
	panel.add_theme_stylebox_override("panel", style)

	var vbox: VBoxContainer = VBoxContainer.new()
	panel.add_child(vbox)

	# 2. 标题
	var title_label: RichTextLabel = RichTextLabel.new()
	title_label.bbcode_enabled = true
	title_label.fit_content = true
	title_label.selection_enabled = false

	title_label.append_text("[b][color=cyan]🔧 Tool Call:[/color][/b] [color=yellow]%s[/color]" % clean_name)
	vbox.add_child(title_label)

	# 3. 参数详情
	var args_label: RichTextLabel = RichTextLabel.new()
	args_label.name = "ArgsLabel"
	args_label.bbcode_enabled = true
	args_label.fit_content = true
	vbox.add_child(args_label)

	_update_args_display(args_label, p_tool_call)

	_content_container.add_child(panel)
	_last_ui_node = null


## 显示图片内容
## [param p_data]: 图片数据
## [param p_mime]: 图片 MIME 类型
func display_image(p_data: PackedByteArray, p_mime: String) -> void:
	if p_data.is_empty():
		return

	var img: Image = Image.new()
	var err: Error = OK

	match p_mime:
		"image/png":
			err = img.load_png_from_buffer(p_data)
		"image/jpeg", "image/jpg":
			err = img.load_jpg_from_buffer(p_data)
		_:
			err = img.load_png_from_buffer(p_data)

	if err == OK:
		var tex: ImageTexture = ImageTexture.create_from_image(img)
		var rect: TextureRect = TextureRect.new()
		rect.texture = tex
		rect.size = Vector2(400, 400)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
		rect.custom_minimum_size = Vector2(400, 400)

		_content_container.add_child(rect)
		_last_ui_node = null
	else:
		AIChatLogger.error("Failed to load image buffer in ChatMessageBlock, error code: %d" % err)


## 挂起内容渲染（用于视口外优化）
func suspend_content() -> void:
	if _is_suspended or _typing_active:
		return

	# [优化P2] 无论折叠与否，统一移除内容以彻底释放布局压力
	custom_minimum_size.y = size.y
	remove_child(_main_margin_container)
	_is_suspended = true


## 恢复内容渲染（用于进入视口）
func resume_content() -> void:
	if not _is_suspended:
		return

	add_child(_main_margin_container)
	custom_minimum_size.y = 0
	_is_suspended = false


## 查询是否处于挂起状态
func is_suspended() -> bool:
	return _is_suspended


# --- Private Functions ---

## 解析器信号回调：将解析段落路由到对应的 UI 渲染方法
func _on_parser_segment_parsed(p_type: int, p_content: String, p_meta: String) -> void:
	var instant: bool = not _streaming

	match p_type:
		MarkdownStreamParser.SegmentType.TEXT:
			_append_to_text(p_content, instant)

		MarkdownStreamParser.SegmentType.CODE_BLOCK_START:
			_finish_typing()
			_create_code_block(p_meta)

		MarkdownStreamParser.SegmentType.CODE_BLOCK_CONTENT:
			_append_to_code(p_content)

		MarkdownStreamParser.SegmentType.CODE_BLOCK_END:
			_last_ui_node = null


# 设置标题和角色元数据
func _set_title(p_role: String, p_model_name: String) -> void:
	set_meta("role", p_role)
	match p_role:
		ChatMessage.ROLE_USER:
			title = "🧑‍💻 You"
			if is_folded():
				expand()

		ChatMessage.ROLE_ASSISTANT:
			title = "🤖 Assistant" + ("/" + p_model_name if not p_model_name.is_empty() else "")
			if is_folded():
				expand()

		ChatMessage.ROLE_TOOL:
			title = "⚙️ Tool Output"
			if not is_folded():
				fold()

		_:
			title = p_role.capitalize()
			if is_folded():
				expand()


# 更新流式工具调用参数 UI
func _update_tool_call_ui(p_node_name: String, p_tool_call: Dictionary) -> void:
	var panel: Node = _content_container.get_node_or_null(p_node_name)
	if panel:
		var args_label: RichTextLabel = panel.find_child("ArgsLabel", true, false)
		if args_label:
			_update_args_display(args_label, p_tool_call)


# 解析并格式化参数显示
func _update_args_display(p_label: RichTextLabel, p_tool_call: Dictionary) -> void:
	var args_str: String = ""
	if p_tool_call.has("function"):
		args_str = p_tool_call.function.get("arguments", "")
	else:
		args_str = str(p_tool_call.get("arguments", ""))

	p_label.clear()
	p_label.push_color(Color(0.7, 0.7, 0.7))

	if args_str.strip_edges().begins_with("{"):
		var json_obj: JSON = JSON.new()
		var err: Error = json_obj.parse(args_str)

		if err == OK:
			p_label.add_text(JSON.stringify(json_obj.data, "  "))
		else:
			p_label.add_text(args_str)
	else:
		p_label.add_text(args_str)

	p_label.pop()


# 清空所有内容
func _clear_content() -> void:
	for c in _content_container.get_children():
		c.queue_free()

	if is_instance_valid(_current_popup_code_view_window):
		_current_popup_code_view_window.queue_free()
		_current_popup_code_view_window = null

	if _content_container.has_meta("shown_calls"):
		_content_container.set_meta("shown_calls", [])

	_parser.reset()
	_last_ui_node = null
	_typing_active = false
	_current_typing_node = null
	_reasoning_container = null
	_reasoning_label = null
	# [优化P1] 清空思考内容缓存
	_reasoning_text_cache = ""


# 创建思考内容 UI 结构
func _create_reasoning_ui() -> void:
	_reasoning_container = FoldableContainer.new()
	_reasoning_container.name = "ReasoningContainer"
	_reasoning_container.set_title("🤔 Thinking Process")
	_reasoning_container.fold()
	# [优化P1] 监听折叠/展开信号，实现懒加载
	_reasoning_container.folding_changed.connect(_on_reasoning_fold_changed)

	_content_container.add_child(_reasoning_container)
	_content_container.move_child(_reasoning_container, 0)

	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)

	_reasoning_container.add_child(margin)

	# [优化P0] 使用 TextEdit 替代 RichTextLabel
	# TextEdit 自带行级虚拟化，只渲染可见行，对超长文本性能优异
	# RichTextLabel + fit_content = true 必须同步计算全部文本高度，长文本会阻塞主线程
	_reasoning_label = TextEdit.new()
	_reasoning_label.editable = false
	_reasoning_label.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_reasoning_label.custom_minimum_size.y = 300
	_reasoning_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_reasoning_label.caret_blink = false
	_reasoning_label.highlight_current_line = false
	_reasoning_label.modulate = Color(0.6, 0.6, 0.6)

	margin.add_child(_reasoning_label)
	_last_ui_node = null


# [优化P1] 思考内容折叠/展开懒加载回调
# 折叠时清空 TextEdit 文本释放布局压力，展开时从缓存填充
func _on_reasoning_fold_changed(is_folded: bool) -> void:
	if is_folded:
		# 折叠：将文本保存到缓存，清空 TextEdit
		if is_instance_valid(_reasoning_label) and not _reasoning_label.text.is_empty():
			_reasoning_text_cache = _reasoning_label.text
			_reasoning_label.text = ""
	else:
		# 展开：从缓存恢复文本到 TextEdit
		if not _reasoning_text_cache.is_empty() and is_instance_valid(_reasoning_label):
			_reasoning_label.text = _reasoning_text_cache
			_reasoning_text_cache = ""


# 创建文本块 UI
func _create_text_block(p_initial_text: String, p_instant: bool) -> RichTextLabel:
	var rtl: RichTextLabel = RichTextLabel.new()
	rtl.bbcode_enabled = false
	rtl.fit_content = true
	rtl.selection_enabled = true
	rtl.focus_mode = Control.FOCUS_CLICK
	rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rtl.text = p_initial_text

	if not p_instant:
		rtl.visible_characters = 0
	_content_container.add_child(rtl)
	return rtl


# 追加内容到文本块
func _append_to_text(p_text: String, p_instant: bool) -> void:
	if not _last_ui_node is RichTextLabel:
		_finish_typing()
		_last_ui_node = _create_text_block("", p_instant)

	if p_instant:
		_last_ui_node.text += p_text
	else:
		var old_total: int = _last_ui_node.get_total_character_count()
		if _last_ui_node.visible_characters == -1:
			_last_ui_node.visible_characters = old_total

		_last_ui_node.text += p_text
		_trigger_typewriter(_last_ui_node)


# 创建代码块 UI
func _create_code_block(p_lang: String) -> void:
	_finish_typing()

	var code_edit: CodeEdit = CodeEdit.new()
	code_edit.editable = false
	code_edit.syntax_highlighter = SYNTAX_HIGHLIGHTER_RES
	code_edit.scroll_fit_content_height = true
	code_edit.draw_tabs = true
	code_edit.gutters_draw_line_numbers = true
	code_edit.minimap_draw = false
	code_edit.wrap_mode = CodeEdit.LINE_WRAPPING_NONE
	code_edit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	code_edit.mouse_filter = CodeEdit.MOUSE_FILTER_PASS

	_content_container.add_child(code_edit)
	_last_ui_node = code_edit

	var header: HBoxContainer = HBoxContainer.new()
	var lang_label: Label = Label.new()
	lang_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lang_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_CHAR
	lang_label.text = p_lang if not p_lang.is_empty() else "Code"
	lang_label.modulate = Color(0.7, 0.7, 0.7)

	var copy_code_button: Button = Button.new()
	copy_code_button.text = "Copy"
	copy_code_button.flat = true
	copy_code_button.focus_mode = Control.FOCUS_NONE

	copy_code_button.pressed.connect(func():
		DisplayServer.clipboard_set(code_edit.text)

		if copy_code_button.text != "Copied ✓":
			var original_text: String = "Copy"
			copy_code_button.text = "Copied ✓"
			copy_code_button.modulate = Color.GREEN_YELLOW

			if copy_code_button.is_inside_tree():
				await copy_code_button.get_tree().create_timer(3.0).timeout

			if is_instance_valid(copy_code_button):
				copy_code_button.text = original_text
				copy_code_button.modulate = Color.WHITE
	)

	header.add_child(lang_label)
	header.add_child(Control.new())
	header.get_child(1).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(copy_code_button)

	var popup_code_window_button: Button = Button.new()
	popup_code_window_button.text = "Popout"
	popup_code_window_button.flat = true
	popup_code_window_button.focus_mode = Control.FOCUS_NONE
	popup_code_window_button.pressed.connect(func():
		DisplayServer.clipboard_set(code_edit.text)
		var code_content: String = DisplayServer.clipboard_get()
		AIChatLogger.debug(code_content)
		_show_code_in_popup_window(code_content)
	)

	header.add_child(popup_code_window_button)
	_content_container.move_child(code_edit, _content_container.get_child_count() - 1)
	_content_container.add_child(header)
	_content_container.move_child(header, _content_container.get_child_count() - 2)


# 追加内容到代码块
func _append_to_code(p_text: String) -> void:
	if _last_ui_node is CodeEdit:
		_last_ui_node.insert_text_at_caret(p_text)


# 触发打字机效果
func _trigger_typewriter(p_node: RichTextLabel) -> void:
	_current_typing_node = p_node
	if not _typing_active:
		_typing_active = true
		_typewriter_loop()


# 强制结束打字机效果
func _finish_typing() -> void:
	if _typing_active and is_instance_valid(_current_typing_node):
		_current_typing_node.visible_characters = -1
		_typing_active = false


# 打字机循环逻辑
func _typewriter_loop() -> void:
	if not _typing_active or not is_instance_valid(_current_typing_node):
		_typing_active = false
		return

	var total: int = _current_typing_node.get_total_character_count()
	var current: int = _current_typing_node.visible_characters

	if current == -1:
		current = total

	var lag: int = total - current

	if lag <= 0:
		_current_typing_node.visible_characters = -1
		_typing_active = false
		return

	var step: int = 1
	if lag > 100:
		step = 20
	elif lag > 50:
		step = 10
	elif lag > 20:
		step = 5
	elif lag > 5:
		step = 2
	else:
		step = 1

	_current_typing_node.visible_characters += step
	get_tree().create_timer(0.016).timeout.connect(_typewriter_loop)


# 打开独立代码查看窗口
func _show_code_in_popup_window(p_code_content: String) -> void:
	var new_popup_code_viewer_window: PopupCodeViewWindow = CODE_VIEWER_WINDOW_RES.instantiate()
	_current_popup_code_view_window = new_popup_code_viewer_window
	add_child(_current_popup_code_view_window)

	_current_popup_code_view_window.get_ok_button().pressed.connect(func():
		remove_child(_current_popup_code_view_window)
		_current_popup_code_view_window.queue_free()
		_current_popup_code_view_window = null

		await get_tree().create_timer(1.0).timeout
		if is_instance_valid(new_popup_code_viewer_window):
			AIChatLogger.debug("PopupCodeViewWindow Instance is still in Memory")
		else:
			AIChatLogger.debug("PopupCodeViewWindow Instance has been removed from Memory")
	)

	_current_popup_code_view_window.visible = true
	var code_edit: CodeEdit = _current_popup_code_view_window.popup_code_edit
	code_edit.text = p_code_content
	_current_popup_code_view_window.popup_centered(Vector2i(800, 600))
