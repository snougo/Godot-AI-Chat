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

## 角色标题样式资源
const TITLE_STYLE_ASSISTANT: StyleBoxFlat = preload("res://addons/godot_ai_chat/assets/assistant_title.tres")
const TITLE_STYLE_USER: StyleBoxFlat = preload("res://addons/godot_ai_chat/assets/user_title.tres")
const TITLE_STYLE_TOOL: StyleBoxFlat = preload("res://addons/godot_ai_chat/assets/tool_title.tres")
## 统一背景样式资源
const BG_STYLE: StyleBoxFlat = preload("res://addons/godot_ai_chat/assets/message_background.tres")

## 行内代码颜色
const INLINE_CODE_COLOR: Color = Color("#d2cf95")
## 段落实体类型（与 MarkdownToBBCode 保持一致）
const SEGMENT_PLAIN: int = 0
const SEGMENT_CODE: int = 1

## 思考内容单帧渲染上限（字符）
const REASONING_RENDER_CHUNK_CHARS: int = 8192
## 思考内容单帧渲染时间预算（微秒）；文档推荐 get_ticks_usec 做精确计时（单调、不受系统时钟影响）
const REASONING_RENDER_BUDGET_USEC: int = 8000
## 思考内容可视高度
const REASONING_VIEW_HEIGHT: float = 200.0
## 思考内容换行模式
## LINE_WRAPPING_NONE 时 get_total_visible_line_count() 等价于 get_line_count()（无需逐行换行测量），
## 是最省 CPU 的模式，代价是超长行需要横向滚动。若横向滚动体验不可接受，改为 LINE_WRAPPING_BOUNDARY。
const REASONING_WRAP_MODE: TextEdit.LineWrappingMode = TextEdit.LINE_WRAPPING_BOUNDARY
## [临时探针] 单次写入耗时告警阈值（微秒）：超过则打印，用于确认卡顿是否仍在写入路径
const REASONING_PROBE_WARN_USEC: int = 30000


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
# [优化P0] 使用 TextEdit（绘制成本与可见行相关），避免 RichTextLabel + fit_content 必须同步全量高度
var _reasoning_label: TextEdit = null
# [优化P2] 待渲染分片队列：只保存"尚未灌入 TextEdit 视图"的内容（视图即已渲染结果）
# 用 PackedStringArray 累积，避免 String 反复整体拼接
var _reasoning_chunks: PackedStringArray = PackedStringArray()
# 分帧渲染游标：下一个待渲染分片下标 + 该分片内已渲染的字符数
var _reasoning_render_chunk: int = 0
var _reasoning_render_offset: int = 0
# 分帧渲染是否在运行
var _reasoning_fill_active: bool = false

# 消息块是否被挂起
var _is_suspended: bool = false

# 标记是否还在消息开头位置（用于跳过开头空白行）
var _is_first_text: bool = true
# 标记上一行是否为空白行（用于压缩连续空白行）
var _previous_line_was_blank: bool = false

# 当前打开的代码查看窗口引用
var _current_popup_code_view_window: PopupCodeViewWindow = null

# 表格渲染状态
var _in_table: bool = false

# 工具角色专用：单一 TextEdit，不走 Markdown 解析器
var _tool_text_edit: TextEdit = null


# --- Built-in Functions ---

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _is_suspended and is_instance_valid(_main_margin_container):
			_main_margin_container.queue_free()


func _ready() -> void:
	_parser.segment_parsed.connect(_on_parser_segment_parsed)
	if not _content_container:
		# 等待一帧以确保节点就绪 (主要用于 Tool 模式下的实例化)
		await get_tree().process_frame


# --- Public Functions ---

## 设置消息内容（静态加载）
func set_content(p_role: String, p_content: String, p_model_name: String = "", p_tool_calls: Array = [], p_reasoning: String = "") -> void:
	_set_title(p_role, p_model_name)
	_clear_content()
	
	# 工具角色：不走解析器，全部塞入单个 TextEdit
	if p_role == ChatMessage.ROLE_TOOL:
		_create_tool_output_block()
		_tool_text_edit.text = p_content
		return
	
	if not p_reasoning.is_empty():
		append_reasoning(p_reasoning)
	
	_streaming = false
	_parser.feed(p_content)
	_parser.flush()
	_close_table_if_open()
	
	for tc in p_tool_calls:
		show_tool_call(tc)


## 开始流式接收消息
func start_stream(p_role: String, p_model_name: String = "") -> void:
	_set_title(p_role, p_model_name)
	_clear_content()
	
	# 工具角色流式模式
	if p_role == ChatMessage.ROLE_TOOL:
		_create_tool_output_block()
		_streaming = true
		return
	
	_streaming = true
	visible = true


## 追加流式文本块
## [param p_text]: 新增的文本片段
func append_chunk(p_text: String) -> void:
	if p_text.is_empty():
		return
	
	# 工具模式：追加到 TextEdit，不走解析器
	if is_instance_valid(_tool_text_edit):
		_tool_text_edit.text += p_text
		_tool_text_edit.scroll_vertical = _tool_text_edit.get_line_count() - 1
		return
	
	_parser.feed(p_text)


## 追加流式思考内容
## [param p_text]: 新增的思考内容片段
func append_reasoning(p_text: String) -> void:
	if p_text.is_empty():
		return
	
	if not is_instance_valid(_reasoning_container):
		_create_reasoning_ui()
	
	# 只入队，不直接写 TextEdit：
	# 折叠状态下为隐藏控件付排版成本没有意义；展开状态下由分帧渲染统一增量写入
	_reasoning_chunks.append(p_text)
	
	if not _reasoning_container.is_folded():
		_start_reasoning_fill()


## 结束流式接收，刷新解析器缓冲区
func finish_stream() -> void:
	# 工具模式：无需特殊处理
	if is_instance_valid(_tool_text_edit):
		return
	
	# 思考内容收尾：仅展开状态下继续补帧，折叠状态下留到用户展开时再渲染
	if is_instance_valid(_reasoning_container) and not _reasoning_container.is_folded():
		_start_reasoning_fill()
	
	_parser.flush()
	_close_table_if_open()
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
	var clean_name: String = tool_name.replace("tool_call", "").strip_edges()
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
	
	title_label.append_text("[color=yellow]%s[/color]" % clean_name)
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
	
	# 无论折叠与否，统一移除内容以彻底释放布局压力
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
	
	# 挂起期间控件离开场景树，分帧渲染会中断；恢复后接着把未渲染的内容补上
	if is_instance_valid(_reasoning_container) and not _reasoning_container.is_folded():
		_start_reasoning_fill()


## 查询是否处于挂起状态
func is_suspended() -> bool:
	return _is_suspended


# --- Private Functions ---

# 闭合未关闭的表格（流结束或静态加载结束时调用）
func _close_table_if_open() -> void:
	if _in_table:
		_in_table = false
		if is_instance_valid(_last_ui_node) and _last_ui_node is RichTextLabel:
			_last_ui_node.append_text("[/table]\n\n")


# 解析器信号回调：将解析段落路由到对应的 UI 渲染方法
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
	
	# 根据角色选择对应的标题样式
	var title_style: StyleBoxFlat
	match p_role:
		ChatMessage.ROLE_USER:
			title = "🧑‍💻 You"
			title_style = TITLE_STYLE_USER
		
		ChatMessage.ROLE_ASSISTANT:
			title = "🤖 Assistant" + ("/" + p_model_name if not p_model_name.is_empty() else "")
			title_style = TITLE_STYLE_ASSISTANT
		
		ChatMessage.ROLE_TOOL:
			title = "🔧 Tool Output"
			title_style = TITLE_STYLE_TOOL
		
		_:
			title = p_role.capitalize()
			title_style = TITLE_STYLE_ASSISTANT
	
	# 统一折叠/展开控制：工具角色默认折叠，其余默认展开
	var should_expand := (p_role != ChatMessage.ROLE_TOOL)
	if should_expand and is_folded():
		expand()
	elif not should_expand and not is_folded():
		fold()
	
	# 设置标题区域样式（4个状态统一使用角色样式）
	add_theme_stylebox_override("title_panel", title_style)
	add_theme_stylebox_override("title_hover_panel", title_style)
	add_theme_stylebox_override("title_collapsed_panel", title_style)
	add_theme_stylebox_override("title_collapsed_hover_panel", title_style)
	
	# 设置统一背景样式
	add_theme_stylebox_override("focus", BG_STYLE)
	add_theme_stylebox_override("panel", BG_STYLE)


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


# 创建思考内容 UI 结构
func _create_reasoning_ui() -> void:
	_reasoning_container = FoldableContainer.new()
	_reasoning_container.name = "ReasoningContainer"
	_reasoning_container.set_title("Thinking Process")
	_reasoning_container.fold()
	# [优化P2] 折叠/展开信号：折叠时暂停补帧，展开时按需补帧
	_reasoning_container.folding_changed.connect(_on_reasoning_fold_changed)
	
	_content_container.add_child(_reasoning_container)
	_content_container.move_child(_reasoning_container, 0)
	
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	
	_reasoning_container.add_child(margin)
	
	# [优化P0] 使用 TextEdit（绘制成本与可见行相关）
	# 常态保持 editable = false：既能拖选/复制（与旧实现一致），也不接受用户编辑。
	# 注意：editable == false 时引擎会拒绝新增文本（文档："new text cannot be added"），
	# 因此增量写入由 _insert_reasoning_text() 临时放行后立刻收回，绝不能常开。
	_reasoning_label = TextEdit.new()
	_reasoning_label.editable = false
	_reasoning_label.wrap_mode = REASONING_WRAP_MODE
	_reasoning_label.custom_minimum_size.y = REASONING_VIEW_HEIGHT
	_reasoning_label.mouse_filter = Control.MOUSE_FILTER_PASS
	_reasoning_label.caret_blink = false
	_reasoning_label.highlight_current_line = false
	_reasoning_label.modulate = Color(0.6, 0.6, 0.6)
	
	margin.add_child(_reasoning_label)
	_last_ui_node = null


# 思考内容折叠/展开回调
# [优化P2] 折叠时不再清空 TextEdit：已渲染内容原样保留，再次展开为零成本
# （旧实现每次展开都要重建整篇文本，这是"点开就卡"的直接原因）
func _on_reasoning_fold_changed(p_is_folded: bool) -> void:
	if p_is_folded:
		_reasoning_fill_active = false
		return
	
	_start_reasoning_fill()


# 启动分帧渲染；已在运行时不重复启动
func _start_reasoning_fill() -> void:
	if _reasoning_fill_active or not is_instance_valid(_reasoning_label):
		return
	
	_reasoning_fill_active = true
	_process_reasoning_fill()


# 分帧把待渲染的思考内容灌入 TextEdit
#
# 单帧工作量受 REASONING_RENDER_CHUNK_CHARS 与 REASONING_RENDER_BUDGET_USEC 双重约束，
# 因此无论思考内容多长，都不会出现"某帧做几秒的活"，也就不会卡住编辑器主线程。
func _process_reasoning_fill() -> void:
	if not is_instance_valid(_reasoning_label) or not _reasoning_label.is_inside_tree() or not is_inside_tree():
		_reasoning_fill_active = false
		return
	
	# 折叠状态下停止补帧：剩余内容留在 _reasoning_chunks 中，展开时再从游标续上。
	# 否则折叠前挂起的下一帧回调仍会继续渲染隐藏控件，白白占用主线程。
	if is_instance_valid(_reasoning_container) and _reasoning_container.is_folded():
		_reasoning_fill_active = false
		return
	
	var frame_start_usec: int = Time.get_ticks_usec()
	
	while true:
		var pending_text: String = _take_reasoning_pending_text()
		if pending_text.is_empty():
			break
		
		_insert_reasoning_text(pending_text)
		
		if Time.get_ticks_usec() - frame_start_usec >= REASONING_RENDER_BUDGET_USEC:
			break
	
	if _reasoning_render_chunk < _reasoning_chunks.size():
		# 还有剩余内容：下一帧继续（单次连接，避免与 _reasoning_fill_active 叠加）
		get_tree().process_frame.connect(_process_reasoning_fill, CONNECT_ONE_SHOT)
	else:
		# 全部渲染完毕：释放已消费的分片（渲染结果已保存在 TextEdit 中）
		_reasoning_chunks.clear()
		_reasoning_render_chunk = 0
		_reasoning_render_offset = 0
		_reasoning_fill_active = false


# 取出下一段待渲染内容（最多 REASONING_RENDER_CHUNK_CHARS 个字符）并推进渲染游标
func _take_reasoning_pending_text() -> String:
	var text: String = ""
	
	while _reasoning_render_chunk < _reasoning_chunks.size() and text.length() < REASONING_RENDER_CHUNK_CHARS:
		var chunk: String = _reasoning_chunks[_reasoning_render_chunk]
		var remain: int = chunk.length() - _reasoning_render_offset
		
		if remain <= 0:
			_reasoning_render_chunk += 1
			_reasoning_render_offset = 0
			continue
		
		var take: int = mini(remain, REASONING_RENDER_CHUNK_CHARS - text.length())
		text += chunk.substr(_reasoning_render_offset, take)
		_reasoning_render_offset += take
		
		if _reasoning_render_offset >= chunk.length():
			_reasoning_render_chunk += 1
			_reasoning_render_offset = 0
	
	return text


# 把一段文本增量追加到思考框末尾
# 只对末尾行做增量插入，单次成本与已渲染总长度无关（这是消除卡顿的关键）。
# editable 在插入前后临时放行/收回：既让引擎接受增量写入，又保持控件常态只读。
func _insert_reasoning_text(p_text: String) -> void:
	var last_line: int = maxi(_reasoning_label.get_line_count() - 1, 0)
	var last_column: int = _reasoning_label.get_line(last_line).length()
	
	var probe_start_usec: int = Time.get_ticks_usec()
	_reasoning_label.editable = true
	_reasoning_label.insert_text(p_text, last_line, last_column, false, false)
	_reasoning_label.editable = false
	
	# [临时探针] 写入仍超阈值则说明瓶颈不在扩展脚本侧的写入路径
	var elapsed_usec: int = Time.get_ticks_usec() - probe_start_usec
	if elapsed_usec >= REASONING_PROBE_WARN_USEC:
		AIChatLogger.debug("Reasoning insert slow: %d chars, %d usec" % [p_text.length(), elapsed_usec])


# 创建文本块 UI
func _create_text_block(p_initial_text: String, p_instant: bool) -> RichTextLabel:
	var rtl: RichTextLabel = RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.fit_content = true
	rtl.selection_enabled = true
	rtl.focus_mode = Control.FOCUS_CLICK
	rtl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	
	# 处理 URL 链接点击，打开系统默认浏览器
	rtl.meta_clicked.connect(func(p_meta: Variant):
		if typeof(p_meta) == TYPE_STRING:
			var url: String = p_meta as String
			if url.begins_with("http://") or url.begins_with("https://"):
				OS.shell_open(url)
	)
	
	var segments: Array[Dictionary] = MarkdownToBBCode.convert_line_to_segments(p_initial_text)
	rtl.clear()
	_render_segments(rtl, segments)
	
	if not p_initial_text.is_empty():
		_is_first_text = false
	_previous_line_was_blank = rtl.text.is_empty() or rtl.text == "\n"
	
	if not p_instant:
		rtl.visible_characters = 0
	_content_container.add_child(rtl)
	return rtl


# 追加内容到文本块
func _append_to_text(p_text: String, p_instant: bool) -> void:
	if not _last_ui_node is RichTextLabel:
		_finish_typing()
		_last_ui_node = _create_text_block("", p_instant)
	
	# --- 表格行检测（优先处理） ---
	var line: String = p_text.trim_suffix("\n").strip_edges()
	var is_table_row: bool = line.begins_with("|")
	
	if is_table_row:
		var check: String = line.replace("|", "").replace("-", "").replace(" ", "").replace(":", "")
		if check.is_empty():
			return
		
		var cells: Array = MarkdownToBBCode.make_table_row_segments(line)
		var is_header: bool = not _in_table
		
		if is_header:
			_in_table = true
			_last_ui_node.append_text("[table=%d]" % cells.size())
			for cell_segs: Array in cells:
				_last_ui_node.append_text("[cell bg=#2d2d5e][b]")
				_render_segments(_last_ui_node, cell_segs)
				_last_ui_node.append_text("[/b][/cell]")
		else:
			for cell_segs: Array in cells:
				_last_ui_node.append_text("[cell]")
				_render_segments(_last_ui_node, cell_segs)
				_last_ui_node.append_text("[/cell]")
		_last_ui_node.append_text("\n")
		return
	
	# 非表格行：先闭合未关闭的表格
	if _in_table:
		_in_table = false
		_last_ui_node.append_text("[/table]\n\n")
	
	var segments: Array[Dictionary] = MarkdownToBBCode.convert_line_to_segments(p_text)
	var is_blank: bool = (segments.is_empty() or _is_blank_segments(segments)) and p_text.strip_edges().is_empty()
	
	# 开头空行 → 跳过（不渲染）
	if _is_first_text and is_blank:
		return
	
	# 连续多余的空行 → 跳过（压缩为1个）
	if is_blank and _previous_line_was_blank:
		return
	
	# 需要保留的单个空行（非开头、上一行不是空行）→ 渲染一个换行符
	if is_blank:
		_last_ui_node.append_text("\n")
		_previous_line_was_blank = true
		_is_first_text = false
		return
	
	_previous_line_was_blank = is_blank
	_is_first_text = false
	
	if p_instant:
		_render_segments(_last_ui_node, segments)
	else:
		var old_total: int = _last_ui_node.get_total_character_count()
		if _last_ui_node.visible_characters == -1:
			_last_ui_node.visible_characters = old_total
		_render_segments(_last_ui_node, segments)
		_trigger_typewriter(_last_ui_node)


# 创建代码块 UI
func _create_code_block(p_lang: String) -> void:
	_close_table_if_open()
	_finish_typing()
	
	var code_edit: CodeEdit = CodeEdit.new()
	code_edit.editable = false
	code_edit.syntax_highlighter = SYNTAX_HIGHLIGHTER_RES
	code_edit.scroll_fit_content_height = true
	code_edit.custom_maximum_size.y = 600
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
	_content_container.add_child(header)
	_content_container.move_child(header, _content_container.get_child_count() - 2)


# 追加内容到代码块
func _append_to_code(p_text: String) -> void:
	if _last_ui_node is CodeEdit:
		_last_ui_node.insert_text_at_caret(p_text)


func _create_tool_output_block() -> void:
	_tool_text_edit = TextEdit.new()
	# 注意：此处依赖 text 属性 setter（不受 editable 约束）写入内容。
	# 若将来改用 insert_text() 增量写入，必须仿照 _insert_reasoning_text()
	# 在调用前后临时放行 editable，否则 editable == false 时新增文本会被引擎静默丢弃。
	_tool_text_edit.editable = false
	_tool_text_edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_tool_text_edit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tool_text_edit.scroll_fit_content_height = true
	_tool_text_edit.custom_maximum_size.y = 600
	_tool_text_edit.caret_blink = false
	_tool_text_edit.highlight_current_line = false
	# 让鼠标滚轮穿透，避免不可编辑的文本框拦截滚动
	_tool_text_edit.mouse_filter = Control.MOUSE_FILTER_PASS
	_content_container.add_child(_tool_text_edit)
	_last_ui_node = _tool_text_edit


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


func _render_segments(rtl: RichTextLabel, segments: Array[Dictionary]) -> void:
	for seg in segments:
		match seg.type:
			SEGMENT_PLAIN:
				# 字面方括号改用 add_text 渲染，规避流式打字机下 [lb]/[rb] 被字面显示的问题
				if seg.content == "[lb]":
					rtl.add_text("[")
				elif seg.content == "[rb]":
					rtl.add_text("]")
				else:
					rtl.append_text(seg.content)
			SEGMENT_CODE:
				rtl.push_color(INLINE_CODE_COLOR)
				rtl.add_text(seg.content)
				rtl.pop()


static func _is_blank_segments(segments: Array[Dictionary]) -> bool:
	if segments.size() != 1:
		return false
	var seg: Dictionary = segments[0]
	return seg.type == SEGMENT_PLAIN and seg.content.strip_edges().is_empty()


# 清空所有内容
func _clear_content() -> void:
	# queue_free 后变量要清掉
	_tool_text_edit = null
	
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
	# 重置思考内容分帧渲染状态
	_reasoning_chunks.clear()
	_reasoning_render_chunk = 0
	_reasoning_render_offset = 0
	_reasoning_fill_active = false
	# 重置时恢复标志位
	_is_first_text = true
	_previous_line_was_blank = false
	# 重置表格状态
	_in_table = false
