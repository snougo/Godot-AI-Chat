@tool
class_name ChatMessageBlock
extends FoldableContainer

## 消息显示块
##
## 负责单条消息的 UI 渲染，支持 Markdown 解析、代码高亮、打字机效果和工具调用展示。
## Markdown 解析逻辑已分离至 MarkdownStreamParser，本类仅负责 UI 渲染。


# --- Constants ---

const MarkdownToBBCode := preload("res://addons/godot_ai_chat/scripts/helper/markdown_to_bbcode.gd")
const MarkdownStreamParser := preload("res://addons/godot_ai_chat/scripts/helper/markdown_stream_parser.gd")

## 预加载代码高亮主题
const SYNTAX_HIGHLIGHTER_RES: CodeHighlighter = preload(PluginPaths.CODE_HIGHLIGHT_THEME)

## 角色标题样式资源
const TITLE_STYLE_ASSISTANT: StyleBoxFlat = preload("res://addons/godot_ai_chat/assets/assistant_title.tres")
const TITLE_STYLE_USER: StyleBoxFlat = preload("res://addons/godot_ai_chat/assets/user_title.tres")
const TITLE_STYLE_TOOL: StyleBoxFlat = preload("res://addons/godot_ai_chat/assets/tool_title.tres")
## 统一背景样式资源
const BG_STYLE: StyleBoxFlat = preload("res://addons/godot_ai_chat/assets/message_background.tres")

## 行内代码颜色
const INLINE_CODE_COLOR: Color = Color("#d2cf95")

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

## 内联预览显示的工具参数最大字符数
## [为什么必须有上限] 文档创建类工具的 arguments 常达数十~数百 KB，且多为"一整行"的转义 JSON。
## 旧实现对每个参数增量都会：解析全量 JSON → 全量序列化 → 清空并整段重排 RichTextLabel
## →（fit_content + 自动换行测量，对一整行超长文本做断行分析）。
## 这些成本都与参数总长度成正比，且全部发生在主线程、中间没有任何 await 点，
## 于是"一大段 chunk 冲进来"表现为编辑器卡死，历史加载表现为"停在某条消息几秒"。
##
## 预览取小值是安全的：完整参数由查看窗口提供，预览只承担"一眼看出调用了什么工具"。
const TOOL_ARGS_RENDER_LIMIT: int = 600
## 参数长度不超过该值时，内联预览先做一次 JSON 美化（仅影响预览显示）
const TOOL_ARGS_PARSE_LIMIT: int = 600
## 查看窗口中尝试"可读化"渲染的长度上限；超过则直接显示原文，避免点开后长时间无响应
const TOOL_ARGS_VIEWER_PARSE_LIMIT: int = 1048576
## [临时探针] 单次参数渲染耗时告警阈值（微秒），用于验证封顶是否生效
const TOOL_ARGS_PROBE_WARN_USEC: int = 5000

## 查看窗口默认尺寸
const TEXT_VIEWER_WINDOW_SIZE: Vector2i = Vector2i(1000, 800)
## 查看窗口最小尺寸
const TEXT_VIEWER_WINDOW_MIN_SIZE: Vector2i = Vector2i(600, 400)
## 查看窗口四周留白（像素）
const TEXT_VIEWER_MARGIN: float = 8.0
## 查看窗口内容区底部预留高度（像素）：给 AcceptDialog 的按钮区留位。
## 取值与旧版 popup_code_viewer_window.tscn 中的 offset_bottom 一致，避免内容压住 OK 按钮。
const TEXT_VIEWER_BOTTOM_RESERVED: float = 49.0


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

# 文本查看窗口（懒创建并复用；关闭时清空文本）
# [为什么复用] 每次点击都实例化/释放窗口会带来反复创建子窗口与文本缓冲的开销，
# 也容易产生"多窗口互相串扰、关不掉"这类 bug。
var _text_viewer_window: AcceptDialog = null
# 工具参数视图：纯 TextEdit —— 无高亮器、无行号槽、无任何逐行装饰
var _text_viewer_args_edit: TextEdit = null
# 代码视图：CodeEdit —— 保留语法高亮与行号
var _text_viewer_code_edit: CodeEdit = null

# 表格渲染状态
var _in_table: bool = false
# 当前表格的列数（数据行按它补齐/截断）
var _table_columns: int = 0
# 当前表格各列对齐方式（"left" / "center" / "right"）
var _table_aligns: Array[String] = []
# 当前表格已渲染的数据行数（用于隔行底色）
var _table_row_index: int = 0

# Markdown 渲染配色（想跟随编辑器主题时改成 MarkdownPalette.from_base(bg, text)）
var _palette: MarkdownPalette = MarkdownPalette.new()

# 工具角色专用：单一 TextEdit，不走 Markdown 解析器
var _tool_text_edit: TextEdit = null


# --- Built-in Functions ---

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		if _is_suspended and is_instance_valid(_main_margin_container):
			_main_margin_container.queue_free()


func _ready() -> void:
	_parser.text_line.connect(_on_parser_text_line)
	_parser.blank.connect(_on_parser_blank)
	_parser.code_start.connect(_on_parser_code_start)
	_parser.code_line.connect(_on_parser_code_line)
	_parser.code_end.connect(_on_parser_code_end)
	_parser.table_start.connect(_on_parser_table_start)
	_parser.table_row.connect(_on_parser_table_row)
	_parser.table_end.connect(_on_parser_table_end)
	_parser.list_item.connect(_on_parser_list_item)
	_parser.quote.connect(_on_parser_quote)
	_parser.rule.connect(_on_parser_rule)
	
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
	
	# 2. 参数文本框（先建，供标题行的 Popout 按钮引用）
	# 本控件只负责"预览"：实际渲染长度在 _build_args_display_text() 中受常量上限约束。
	# mouse_filter 设为 PASS：面板可能较高，滚轮应继续驱动外层聊天列表滚动。
	var args_label: RichTextLabel = RichTextLabel.new()
	args_label.name = "ArgsLabel"
	args_label.bbcode_enabled = true
	args_label.fit_content = true
	args_label.selection_enabled = true
	args_label.mouse_filter = Control.MOUSE_FILTER_PASS
	# 面板持有引用，供 _update_tool_call_ui() O(1) 取用（替代递归 find_child）
	panel.set_meta("args_label", args_label)
	
	# 3. 标题行：工具名 + 完整参数查看按钮
	# [为什么需要查看窗口] 预览是截断的；完整参数始终完整保存在 meta["full_args"] 中，
	# 由查看窗口按需渲染（一次性静态渲染），而不是塞进会被高频刷新的 RichTextLabel。
	var header: HBoxContainer = HBoxContainer.new()
	
	var title_label: RichTextLabel = RichTextLabel.new()
	title_label.bbcode_enabled = true
	title_label.fit_content = true
	title_label.selection_enabled = false
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_label.append_text("[color=yellow]%s[/color]" % clean_name)
	header.add_child(title_label)
	
	var popout_args_button: Button = Button.new()
	popout_args_button.text = "Popout"
	popout_args_button.flat = true
	popout_args_button.focus_mode = Control.FOCUS_NONE
	popout_args_button.tooltip_text = "在独立窗口中查看完整工具参数（内联预览可能被截断）"
	popout_args_button.pressed.connect(func():
		_show_text_viewer(_build_args_viewer_text(String(args_label.get_meta("full_args", ""))), false)
	)
	header.add_child(popout_args_button)
	
	vbox.add_child(header)
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
	if not panel:
		return
	
	# 用面板 meta 保存的引用替代递归 find_child("ArgsLabel", true, false)：
	# 本函数在流式期间会随参数增量反复调用，没必要每次都做一次子树搜索
	if not panel.has_meta("args_label"):
		return
	var args_label: RichTextLabel = panel.get_meta("args_label") as RichTextLabel
	if args_label == null:
		return
	
	_update_args_display(args_label, p_tool_call)


# 解析并格式化参数预览
# [性能] 显示长度受 TOOL_ARGS_RENDER_LIMIT 约束，单次刷新的成本与参数总长度解耦：
# 流式卡死与历史加载停顿都源于旧实现"每次增量都对全量参数解析 + 序列化 + 整段重排"。
func _update_args_display(p_label: RichTextLabel, p_tool_call: Dictionary) -> void:
	var probe_start_usec: int = Time.get_ticks_usec()
	
	var args_str: String = ""
	if p_tool_call.has("function"):
		args_str = str(p_tool_call.function.get("arguments", ""))
	else:
		args_str = str(p_tool_call.get("arguments", ""))
	
	# 面板始终保留完整参数（供查看窗口使用）；预览文本另行截断
	p_label.set_meta("full_args", args_str)
	
	var display_text: String = _build_args_display_text(args_str)
	
	p_label.clear()
	p_label.push_color(Color(0.7, 0.7, 0.7))
	p_label.add_text(display_text)
	p_label.pop()
	
	# [临时探针] 用于验证封顶是否生效（默认日志级别不含 DEBUG，开销可忽略）
	if AIChatLogger.current_flags & AIChatLogger.FLAG_DEBUG:
		var elapsed_usec: int = Time.get_ticks_usec() - probe_start_usec
		if elapsed_usec >= TOOL_ARGS_PROBE_WARN_USEC:
			AIChatLogger.debug("Tool args render slow: full %d chars -> shown %d chars, %d usec" % [args_str.length(), display_text.length(), elapsed_usec,])


# 构造参数预览文本
func _build_args_display_text(p_args_str: String) -> String:
	# 超大参数直接跳过解析与序列化，只显示截断后的原文
	if p_args_str.length() > TOOL_ARGS_PARSE_LIMIT:
		return _truncate_args_for_display(p_args_str)
	
	if not p_args_str.strip_edges().begins_with("{"):
		return _truncate_args_for_display(p_args_str)
	
	var json_obj: JSON = JSON.new()
	if json_obj.parse(p_args_str) != OK:
		# 流式接收中参数必然是不完整的 JSON，这不是错误：原样显示即可
		return _truncate_args_for_display(p_args_str)
	
	return _truncate_args_for_display(JSON.stringify(json_obj.data, "  "))


# 截断超长参数文本，并附带提示
# 截断发生在美化之后，因此最终显示长度一定不超过 TOOL_ARGS_RENDER_LIMIT
func _truncate_args_for_display(p_text: String) -> String:
	if p_text.length() <= TOOL_ARGS_RENDER_LIMIT:
		return p_text
	
	var suffix: String = "\n… [已截断显示，参数共 %d 字符，完整内容请点 Popout]" % p_text.length()
	return p_text.substr(0, TOOL_ARGS_RENDER_LIMIT) + suffix


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
	
	var segments: Array[MarkdownSegment] = MarkdownToBBCode.convert_line_to_segments(p_initial_text, _palette)
	rtl.clear()
	_render_segments(rtl, segments)
	
	if not p_initial_text.is_empty():
		_is_first_text = false
	# [P0] 原先这里还有一行用 rtl.text 判空白的 _previous_line_was_blank 初始化：
	# rtl.text 是 BBCode 源串而非可见文本，判断不可靠；该状态由 _append_plain_line() 统一维护。
	
	if not p_instant:
		rtl.visible_characters = 0
	_content_container.add_child(rtl)
	return rtl


# 渲染单个单元格（边框、底色、内边距、对齐、表头加粗）
# [为什么必须规整类型] 本函数一旦中途抛错，[cell] 就没有闭合标签，
# 整个 RichTextLabel 的表格结构会直接崩掉（报 ITEM_TABLE 断言）。
# 渲染单个单元格（边框、底色、内边距、对齐、表头加粗）
func _render_table_cell(p_segments: Array[MarkdownSegment], p_column: int, p_is_header: bool) -> void:
	var rtl: RichTextLabel = _last_ui_node as RichTextLabel
	if rtl == null:
		return
	
	var align: String = _get_table_align(p_column)
	
	# 开标签合并成一次 append（cell 属性 + 对齐 + 加粗）
	var open_tag: String = _table_cell_open_tag(p_column, p_is_header)
	if align != "left":
		open_tag += "[p align=%s]" % align
	if p_is_header:
		open_tag += "[b]"
	rtl.append_text(open_tag)
	
	_render_segments(rtl, p_segments)
	
	var close_tag: String = ""
	if p_is_header:
		close_tag += "[/b]"
	if align != "left":
		close_tag += "[/p]"
	close_tag += "[/cell]"
	rtl.append_text(close_tag)


# 构造单元格开标签。边框与内边距必须逐格声明：RichTextLabel 没有表格级样式。
func _table_cell_open_tag(p_column: int, p_is_header: bool) -> String:
	var bg: String = ""
	if p_is_header:
		bg = " bg=#%s" % _palette.table_header_bg.to_html(false)
	elif _table_row_index % 2 == 1:
		# 隔行底色自行按行号奇偶计算，不依赖 cell 的 bg=奇,偶 语法
		bg = " bg=#%s" % _palette.table_row_alt_bg.to_html(false)
	
	return "[cell padding=%d,%d,%d,%d border=#%s%s]" % [
			_palette.cell_pad_h, _palette.cell_pad_v, _palette.cell_pad_h, _palette.cell_pad_v,
			_palette.table_border.to_html(false), bg]


# 取某列的对齐方式，未声明或越界一律按左对齐
func _get_table_align(p_column: int) -> String:
	if p_column >= _table_aligns.size():
		return "left"
	
	var align: String = _table_aligns[p_column]
	return align if not align.is_empty() else "left"


# 普通文本行渲染（含空行压缩）
func _append_plain_line(p_text: String, p_instant: bool) -> void:
	# 原先这一步在 _append_to_text() 开头
	# 现在每个块事件自行进入渲染层，统一放这里
	_ensure_text_block(p_instant)
	
	var rtl: RichTextLabel = _last_ui_node as RichTextLabel
	if rtl == null:
		return
	
	var segments: Array[MarkdownSegment] = MarkdownToBBCode.convert_line_to_segments(p_text, _palette)
	var is_blank: bool = p_text.strip_edges().is_empty()
	
	# 开头空行 → 跳过（不渲染）
	if _is_first_text and is_blank:
		return
	
	# 连续多余的空行 → 跳过（压缩为1个）
	if is_blank and _previous_line_was_blank:
		return
	
	# 需要保留的单个空行（非开头、上一行不是空行）→ 渲染一个换行符
	if is_blank:
		rtl.append_text("\n")
		_previous_line_was_blank = true
		_is_first_text = false
		return
	
	_previous_line_was_blank = false
	_is_first_text = false
	
	if p_instant:
		_render_segments(rtl, segments)
	else:
		var old_total: int = rtl.get_total_character_count()
		if rtl.visible_characters == -1:
			rtl.visible_characters = old_total
		_render_segments(rtl, segments)
		_trigger_typewriter(rtl)


# 创建代码块 UI
func _create_code_block(p_lang: String) -> void:
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
		# 直接传文本给查看窗口：旧实现走"写剪贴板 → 读剪贴板 → 打印全文日志"，
		# 其中的全量日志在 DEBUG 开启时会把整段代码打印进 Output 面板，本身就是一次卡顿。
		_show_text_viewer(code_edit.text, true)
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


# 打开（或复用）文本查看窗口
# [param p_text]: 待显示文本（完整内容，不做截断）
# [param p_is_code_view]: true = 代码视图（语法高亮 + 行号）；false = 工具参数视图（纯文本）
func _show_text_viewer(p_text: String, p_is_code_view: bool) -> void:
	if not is_instance_valid(_text_viewer_window):
		_create_text_viewer_window()
	
	if not is_instance_valid(_text_viewer_args_edit) or not is_instance_valid(_text_viewer_code_edit):
		return
	
	# 两种用途用两个控件表达，而不是靠开关一堆属性：
	# 参数视图在结构上就没有高亮器与行号槽，也就不可能被后续改动"顺手打开"而回归性能。
	_text_viewer_args_edit.visible = not p_is_code_view
	_text_viewer_code_edit.visible = p_is_code_view
	
	if p_is_code_view:
		_text_viewer_code_edit.text = p_text
	else:
		_text_viewer_args_edit.text = p_text
	
	_text_viewer_window.popup_centered(TEXT_VIEWER_WINDOW_SIZE)


# 创建文本查看窗口（纯代码构建，不新增场景资源）
# [为什么代码构建] 窗口的关键配置本身就是性能契约，而 .tscn 不支持注释、编辑器还会重写它，
# 把契约放在场景里等于把理由丢掉；本文件其余 UI（代码块、工具面板、思考框）也一律是代码构建。
func _create_text_viewer_window() -> void:
	var window: AcceptDialog = AcceptDialog.new()
	window.title = "Viewer"
	window.size = TEXT_VIEWER_WINDOW_SIZE
	window.min_size = TEXT_VIEWER_WINDOW_MIN_SIZE
	# 注意：Godot 4 的属性名是 dialog_hide_on_ok（Godot 3 才叫 hide_on_ok）
	window.dialog_hide_on_ok = true
	
	# 复刻旧版场景的布局：四周留白 + 底部给按钮区留位，避免内容压住 OK 按钮
	var margin: MarginContainer = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.offset_left = TEXT_VIEWER_MARGIN
	margin.offset_top = TEXT_VIEWER_MARGIN
	margin.offset_right = -TEXT_VIEWER_MARGIN
	margin.offset_bottom = -TEXT_VIEWER_BOTTOM_RESERVED
	window.add_child(margin)
	
	# 1. 工具参数视图：只设必要项，其余全部沿用 TextEdit 默认值 ——
	#    高亮器默认 null、没有行号槽、draw_tabs / draw_spaces / minimap_draw / scroll_smooth 默认全为 false，
	#    这正是"一个不做任何渲染的 TextEdit"。
	#    wrap 固定 NONE：这是 TextEdit 最省的模式（可见行数 == 逻辑行数，无需逐行换行测量）；
	#    参数文本已按真实换行渲染，本就不需要换行。
	var args_edit: TextEdit = TextEdit.new()
	args_edit.editable = false
	args_edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	args_edit.caret_blink = false
	args_edit.highlight_current_line = false
	margin.add_child(args_edit)
	
	# 2. 代码视图：保留语法高亮与行号（与旧版代码块弹窗一致）
	var code_edit: CodeEdit = CodeEdit.new()
	code_edit.editable = false
	code_edit.syntax_highlighter = SYNTAX_HIGHLIGHTER_RES
	code_edit.gutters_draw_line_numbers = true
	code_edit.draw_tabs = true
	code_edit.minimap_draw = false
	code_edit.wrap_mode = CodeEdit.LINE_WRAPPING_NONE
	# 平滑滚动是"逐帧重绘新露出区域"的持续成本，对查看器不划算（TextEdit 默认即为 false）
	code_edit.scroll_smooth = false
	margin.add_child(code_edit)
	
	# 关闭路径统一处理：OK 按钮 / 右上角关闭 / Esc
	window.confirmed.connect(_on_text_viewer_closed)
	window.canceled.connect(_on_text_viewer_closed)
	window.close_requested.connect(_on_text_viewer_closed)
	
	add_child(window)
	_text_viewer_window = window
	_text_viewer_args_edit = args_edit
	_text_viewer_code_edit = code_edit
	# 验证窗口是否真的被复用：正常应当每个消息块最多出现一次
	AIChatLogger.debug("[ChatMessageBlock] Text viewer created")


# 构造查看窗口显示的工具参数文本
# [性能边界] 只在用户主动点开时执行一次：解析与渲染都是 O(全文)，不在流式热路径上；
# 超过上限时退化为直接显示原文，避免点开后长时间无响应。
func _build_args_viewer_text(p_full_args: String) -> String:
	if p_full_args.is_empty():
		return p_full_args
	if p_full_args.length() > TOOL_ARGS_VIEWER_PARSE_LIMIT:
		return p_full_args
	if not p_full_args.strip_edges().begins_with("{"):
		return p_full_args
	
	var json_obj: JSON = JSON.new()
	if json_obj.parse(p_full_args) != OK:
		return p_full_args
	
	# 头部留一行说明：下方不是原始 JSON 文本，而是可读化渲染
	return "// 参数已按可读形式渲染：字符串值中的换行按真实换行显示\n" + _format_args_readable(json_obj.data)


# 把参数数据渲染为人类可读的多行文本
# [与 JSON.stringify 的差别] 字符串值原样输出（其中已含真实换行与制表符），
# 因此配合 LINE_WRAPPING_NONE 也能纵向阅读，完全不需要逐行换行测量。
# [param p_value]: 已解析的参数数据
# [param p_indent]: 当前缩进
func _format_args_readable(p_value: Variant, p_indent: String = "") -> String:
	var child_indent: String = p_indent + "  "
	
	if p_value is Dictionary:
		var dict: Dictionary = p_value
		if dict.is_empty():
			return "{}"
		var entry_lines: PackedStringArray = PackedStringArray()
		for key: Variant in dict.keys():
			entry_lines.append("%s%s: %s" % [child_indent, str(key), _format_args_readable(dict[key], child_indent)])
		return "{\n" + "\n".join(entry_lines) + "\n" + p_indent + "}"
	
	if p_value is Array:
		var arr: Array = p_value
		if arr.is_empty():
			return "[]"
		var item_lines: PackedStringArray = PackedStringArray()
		for item: Variant in arr:
			item_lines.append(child_indent + _format_args_readable(item, child_indent))
		return "[\n" + "\n".join(item_lines) + "\n" + p_indent + "]"
	
	if p_value is String:
		# 原样输出：换行已是真实换行
		return str(p_value)
	
	return JSON.stringify(p_value)


# 渲染一段 segments 到 RichTextLabel
# [P3 合并] 连续的 PLAIN 片段先拼成字符串再一次性 append_text：一行文本通常被切成
# 5~10 个片段，合并后 append_text 调用次数降到 1~3 次。
# [特例] "[lb]"/"[rb]" 必须走 add_text：流式打字机下它们会被字面显示（既有踩坑记录）。
func _render_segments(p_rtl: RichTextLabel, p_segments: Array[MarkdownSegment]) -> void:
	var buffer: String = ""
	
	for segment in p_segments:
		if segment.kind == MarkdownToBBCode.SEGMENT_CODE:
			if not buffer.is_empty():
				p_rtl.append_text(buffer)
				buffer = ""
			p_rtl.push_color(_palette.inline_code)
			p_rtl.add_text(segment.text)
			p_rtl.pop()
			continue
		
		# PLAIN
		if segment.text == "[lb]" or segment.text == "[rb]":
			if not buffer.is_empty():
				p_rtl.append_text(buffer)
				buffer = ""
			p_rtl.add_text("[" if segment.text == "[lb]" else "]")
		else:
			buffer += segment.text
	
	if not buffer.is_empty():
		p_rtl.append_text(buffer)


# 清空所有内容
func _clear_content() -> void:
	# queue_free 后变量要清掉
	_tool_text_edit = null
	
	for c in _content_container.get_children():
		c.queue_free()
	
	# 查看窗口是消息块的直接子节点（不在 _content_container 内），需要单独释放
	if is_instance_valid(_text_viewer_window):
		_text_viewer_window.queue_free()
	_text_viewer_window = null
	_text_viewer_args_edit = null
	_text_viewer_code_edit = null
	
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
	_table_columns = 0
	_table_aligns.clear()
	_table_row_index = 0


# 确保当前文本块是 RichTextLabel（代码块结束后 _last_ui_node 是 CodeEdit）
# [param p_instant]: true = 整块渲染，不做打字机
func _ensure_text_block(p_instant: bool) -> void:
	if not _last_ui_node is RichTextLabel:
		_finish_typing()
		_last_ui_node = _create_text_block("", p_instant)


# --- Signal Callbacks ---

# 查看窗口关闭回调：隐藏并清空文本
# [为什么清空内容] 文本是内存占用的大头（TextServer 侧的文本缓冲），窗口节点本身很小。
# 关闭即释放内容，既避免"看起来像泄漏"，也省掉每次点击重建窗口的开销。
func _on_text_viewer_closed() -> void:
	if not is_instance_valid(_text_viewer_window):
		return
	
	_text_viewer_window.visible = false
	if is_instance_valid(_text_viewer_args_edit):
		_text_viewer_args_edit.text = ""
	if is_instance_valid(_text_viewer_code_edit):
		_text_viewer_code_edit.text = ""


# 普通段落行
func _on_parser_text_line(p_line: String) -> void:
	_append_plain_line(p_line, not _streaming)


# 空行（交给 _append_plain_line 做压缩，与原先行为一致）
func _on_parser_blank() -> void:
	_append_plain_line("\n", not _streaming)


# 代码块开始
func _on_parser_code_start(p_lang: String) -> void:
	_finish_typing()
	_create_code_block(p_lang)


# 代码块内容行
func _on_parser_code_line(p_line: String) -> void:
	_append_to_code(p_line)


# 代码块结束
func _on_parser_code_end() -> void:
	_last_ui_node = null


# 表格开始：列数与对齐由解析器给出，这里只做渲染准备
func _on_parser_table_start(p_columns: int, p_aligns: Array[String]) -> void:
	# 表格是整块 append 的，先结束打字机：
	# 否则 visible_characters 停在旧值，表格会"藏"在打字机后面（整块延迟出现）
	_finish_typing()
	
	if not _last_ui_node is RichTextLabel:
		_last_ui_node = _create_text_block("", true)
	
	_in_table = true
	_table_columns = p_columns
	_table_aligns = p_aligns
	# 第 0 行就是表头
	_table_row_index = 0
	_is_first_text = false
	_previous_line_was_blank = false
	
	var rtl: RichTextLabel = _last_ui_node as RichTextLabel
	rtl.append_text("[table=%d]" % _table_columns)


# 表格行：第 0 行是表头，其后是数据行
func _on_parser_table_row(p_cells: Array) -> void:
	var rtl: RichTextLabel = _last_ui_node as RichTextLabel
	if rtl == null or not _in_table:
		return
	
	var is_header: bool = (_table_row_index == 0)
	# 单元格数量按表头列数补齐/截断；元素是原始文本，行内转换在这里做
	for column in _table_columns:
		var cell_text: String = p_cells[column] if column < p_cells.size() else ""
		var segments: Array[MarkdownSegment] = MarkdownToBBCode.convert_inline_to_segments(cell_text, _palette)
		_render_table_cell(segments, column, is_header)
	rtl.append_text("\n")
	_table_row_index += 1


# 表格结束
func _on_parser_table_end() -> void:
	if not _in_table:
		return
	
	_in_table = false
	_table_columns = 0
	_table_aligns.clear()
	_table_row_index = 0
	
	var rtl: RichTextLabel = _last_ui_node as RichTextLabel
	if rtl != null:
		rtl.append_text("[/table]\n\n")
		# 表格自身已输出两个换行，紧随的空行不必再补一个
		_previous_line_was_blank = true
		_is_first_text = false


# 列表项
# [标记由渲染层决定] 解析器只给原始标记，符号/编号的表达属于表现层。
func _on_parser_list_item(p_depth: int, p_marker: String, p_text: String) -> void:
	_ensure_text_block(not _streaming)
	
	var rtl: RichTextLabel = _last_ui_node as RichTextLabel
	if rtl == null:
		return
	
	# 无序标记按层级换符号；有序标记（1. / 2) …）原样显示
	var marker: String = p_marker
	if not marker.substr(0, 1).is_valid_int():
		marker = _palette.list_bullets[mini(p_depth, _palette.list_bullets.size() - 1)]
	
	var segments: Array[MarkdownSegment] = MarkdownToBBCode.convert_line_to_segments(p_text, _palette)
	# convert_line_to_segments() 会追加行尾换行；要把它挪到 [/indent] 之后
	if not segments.is_empty() and segments[segments.size() - 1].text == "\n":
		segments.remove_at(segments.size() - 1)
	
	var opens: String = "[indent]".repeat(p_depth + 1)
	var closes: String = "[/indent]".repeat(p_depth + 1)
	
	var instant: bool = not _streaming
	if not instant and rtl.visible_characters == -1:
		rtl.visible_characters = rtl.get_total_character_count()
	
	rtl.append_text("%s%s " % [opens, marker])
	_render_segments(rtl, segments)
	rtl.append_text("%s\n" % closes)
	
	if not instant:
		_trigger_typewriter(rtl)
	
	_is_first_text = false
	_previous_line_was_blank = false


# 引用块（整块交付）：用 2 列表格模拟"左侧竖条 + 底色卡片"
func _on_parser_quote(p_lines: PackedStringArray) -> void:
	if p_lines.is_empty():
		return
	
	_finish_typing()
	_ensure_text_block(true)
	
	var rtl: RichTextLabel = _last_ui_node as RichTextLabel
	if rtl == null:
		return
	
	rtl.append_text("[table=2]")
	# 竖条：不参与宽度分配（expand=0），只有 2px 左右的内边距
	rtl.append_text("[cell expand=0 padding=2,0,2,0 bg=#%s] [/cell]" % _palette.quote_bar.to_html(false))
	rtl.append_text("[cell expand=1 padding=%d,%d,%d,%d bg=#%s]" % [
			_palette.quote_pad, _palette.quote_pad, _palette.quote_pad, _palette.quote_pad,
			_palette.quote_bg.to_html(false),
	])
	
	for line in p_lines:
		if line.strip_edges().is_empty():
			rtl.append_text("\n")
			continue
		var segments: Array[MarkdownSegment] = MarkdownToBBCode.convert_line_to_segments(line, _palette)
		if segments.is_empty():
			rtl.append_text("\n")
		else:
			_render_segments(rtl, segments)
	
	rtl.append_text("[/cell][/table]\n\n")
	
	_is_first_text = false
	_previous_line_was_blank = true


# 分隔线
func _on_parser_rule() -> void:
	_finish_typing()
	_ensure_text_block(true)
	
	var rtl: RichTextLabel = _last_ui_node as RichTextLabel
	if rtl == null:
		return
	
	rtl.append_text("[hr color=#%s height=1 width=100%%]\n" % _palette.table_border.to_html(false))
	
	_is_first_text = false
	_previous_line_was_blank = false
