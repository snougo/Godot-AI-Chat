@tool
class_name ChatMessageBlock
extends FoldableContainer

## 消息显示块
##
## 负责单条消息的 UI 渲染，支持 Markdown 解析、代码高亮、打字机效果和工具调用展示。
## 包含对流式传输内容的智能分块处理。

# --- Enums / Constants ---

## 解析状态
enum ParseState {
	TEXT, ## 正在解析普通文本
	CODE  ## 正在解析代码块
}

## 预加载代码高亮主题
const SYNTAX_HIGHLIGHTER_RES: CodeHighlighter = preload(PluginPaths.CODE_HIGHLIGHT_THEME)
## 预加载代码查看器窗口
const CODE_VIEWER_WINDOW_RES: PackedScene = preload("res://addons/godot_ai_chat/scene/popup_code_viewer_window.tscn")

# --- @onready Vars ---

@onready var _content_container: VBoxContainer = $MarginContainer/VBoxContainer
@onready var _main_margin_container: Control = $MarginContainer

# --- Private Vars ---

# 当前解析状态
var _current_state: ParseState = ParseState.TEXT

# 混合缓冲区：只有当遇到潜在的 ``` 标记时，文本才会被暂时存入这里等待换行确认
var _pending_buffer: String = ""

# 记录上一个创建的 UI 节点，用于连续追加内容
var _last_ui_node: Control = null

# 正则匹配：代码块开始 (锚定行首，缩进允许 0-3 个空格)
# Group 1: Fence (```, ````, etc.)
# Group 2: Language
var _re_code_start: RegEx = RegEx.create_from_string("^ {0,8}(`{3,})\\s*(.*)\\s*$")

# 正则匹配：代码块结束 (锚定行首，缩进允许 0-3 个空格，且仅允许水平空白字符)
# Group 1: Fence
var _re_code_end: RegEx = RegEx.create_from_string("^ {0,8}(`{3,})[ \\t]*$")

# 当前代码块使用的围栏字符串 (如 "```" 或 "````")
var _current_fence_str: String = ""

# 标记当前是否处于行首（用于正确识别代码块围栏）
# 初始为 true，每次 append 内容后，如果内容以换行符结尾，则置为 true，否则 false
var _is_line_start: bool = true

# 打字机状态
var _typing_active: bool = false
# 当前正在执行打字机效果的节点
var _current_typing_node: RichTextLabel = null

# 思考内容 UI 引用
var _reasoning_container: FoldableContainer = null
var _reasoning_label: RichTextLabel = null

# 消息块是否被挂起
var _is_suspended: bool = false

# 当前打开的代码查看窗口引用
var _current_popup_code_view_window: PopupCodeViewWindow = null


# --- Built-in Functions ---

func _ready() -> void:
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
	
	# 静态加载时，直接一次性处理，并在最后强制换行确保闭合
	_process_smart_chunk(p_content + "\n", true)
	
	for tc in p_tool_calls:
		show_tool_call(tc)


## 开始流式接收消息
## [param p_role]: 消息角色
## [param p_model_name]: 模型名称
func start_stream(p_role: String, p_model_name: String = "") -> void:
	_set_title(p_role, p_model_name)
	_clear_content()
	visible = true


## 追加流式文本块
## [param p_text]: 新增的文本片段
func append_chunk(p_text: String) -> void:
	if p_text.is_empty():
		return
	
	# 直接走普通文本/代码块处理逻辑，不再解析 <think> 标签
	# 混合在文本中的思考过程将直接作为普通文本显示
	_process_smart_chunk(p_text, false)


## 追加流式思考内容
## [param p_text]: 新增的思考内容片段
func append_reasoning(p_text: String) -> void:
	if p_text.is_empty():
		return
	
	if not is_instance_valid(_reasoning_container):
		_create_reasoning_ui()
	
	if is_instance_valid(_reasoning_label):
		_reasoning_label.text += p_text


## 结束流式接收，刷新缓冲区
func finish_stream() -> void:
	# 刷新剩余的 Pending Buffer (用于处理未闭合的代码块标记等)
	if not _pending_buffer.is_empty():
		if _pending_buffer.begins_with("```"):
			var line: String = _pending_buffer
			if line.ends_with("\r"):
				line = line.left(-1)
			_parse_fence_line(line, false)
		else:
			_append_content(_pending_buffer, false)
		
		_pending_buffer = ""
	
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
##[param p_tool_call]: 工具调用信息字典
func show_tool_call(p_tool_call: Dictionary) -> void:
	# 提取工具名称
	var tool_name: String = ""
	if p_tool_call.has("function"):
		tool_name = p_tool_call.function.get("name", "unknown")
	else:
		tool_name = p_tool_call.get("name", "unknown")
	
	# [UI防御] 清洗并验证。如果是非法名称，直接忽略，不生成任何 UI
	var clean_name: String = tool_name.replace("<tool_call>", "").replace("</tool_call>", "").replace("tool_call", "").strip_edges()
	if not ToolBox.is_valid_tool_name(clean_name):
		return
	
	var call_id: String = p_tool_call.get("id", "no-id")
	var safe_node_name: String = ("Tool_" + call_id).validate_node_name()
	
	var shown_calls: Array = _content_container.get_meta("shown_calls",[])
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
	
	# [修复] 使用清理后的名称显示，避免出现乱码或多余的标签
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
## 将内容隐藏并用最小高度占位，减少 Draw Calls 和 Update 开销
func suspend_content() -> void:
	# 如果正在打字（生成中）或已经挂起，则不执行
	if _is_suspended or _typing_active:
		return
	
	# 如果是折叠状态，绝不挂起。
	# 并且，强制清除任何可能的最小高度锁定，确保它能塌缩到最小（标题栏高度）。
	if is_folded():
		if custom_minimum_size.y != 0:
			custom_minimum_size.y = 0
		return
	
	# 1. 锁定高度：将当前实际高度设为最小高度，防止布局塌陷
	custom_minimum_size.y = size.y
	
	# 2. 移出节点：彻底移除子节点，阻断 THEME_CHANGED 和 DRAW 调用
	remove_child(_main_margin_container)
	
	_is_suspended = true


## 恢复内容渲染（用于进入视口）
func resume_content() -> void:
	if not _is_suspended:
		return
	
	# 1. 恢复节点
	add_child(_main_margin_container)
	
	# 2. 解除高度锁定（设为0允许自适应，或者保持原状）
	# 通常设为0是安全的，因为内容撑开的高度应该是一样的
	custom_minimum_size.y = 0
	_is_suspended = false


## 查询是否处于挂起状态
func is_suspended() -> bool:
	return _is_suspended


# --- Private Functions ---

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
	
	_current_state = ParseState.TEXT
	_pending_buffer = ""
	_current_fence_str = ""
	_is_line_start = true # 重置为 true
	_last_ui_node = null
	_typing_active = false
	_current_typing_node = null
	_reasoning_container = null
	_reasoning_label = null


# 智能分块处理逻辑
# 核心职责：在流式传输中检测 Markdown 代码块标记（```），解决缩进导致的解析错误
func _process_smart_chunk(p_incoming_text: String, p_instant: bool) -> void:
	_pending_buffer += p_incoming_text
	
	# [Fix] 每个新 chunk 开始时，重置行首状态
	_is_line_start = true
	
	while true:
		# 1. 查找缓冲区中是否存在代码块标记
		var fence_idx: int = _pending_buffer.find("```")
		
		if fence_idx != -1:
			# 2. 回溯检查：判断 ``` 之前是否只有空白字符（空格/制表符）
			# 这是为了支持缩进的代码块（例如 "  ```gdscript"）
			var line_start_idx: int = -1
			var is_valid_fence: bool = false
			var ptr: int = fence_idx - 1
			
			while ptr >= 0:
				var char_code: String = _pending_buffer[ptr]
				if char_code == '\n':
					# 找到上一个换行符，确认是新的一行
					line_start_idx = ptr + 1
					is_valid_fence = true
					break
				elif char_code == ' ' or char_code == '\t':
					# 允许空白字符，继续回溯
					ptr -= 1
				else:
					# 遇到非空白字符（如 "abc ```"），说明不是行首标记
					is_valid_fence = false
					break
			
			if ptr < 0:
				# 回溯到了 buffer 开头
				line_start_idx = 0
				# 关键修正：只有当 buffer 开头确实是行首时，才有效
				is_valid_fence = _is_line_start
			
			# 3. 分支处理：无效标记 vs 有效标记
			if not is_valid_fence:
				# 情况 A: 标记前有杂质，视为普通文本
				# 将此部分（包括杂质）作为文本追加，但需要小心处理后续可能的反引号
				# 例如： "abc ```" 或 "abc ````"
				# 找到 fence 之后第一个非反引号字符的位置，确定要切多少
				var after_fence_idx: int = fence_idx + 3
				while after_fence_idx < _pending_buffer.length():
					if _pending_buffer[after_fence_idx] == '`':
						after_fence_idx += 1
					else:
						break
				
				var safe_part: String = _pending_buffer.substr(0, after_fence_idx)
				_append_content(safe_part, p_instant)
				_pending_buffer = _pending_buffer.substr(after_fence_idx)
				continue
			
			# 情况 B: 是有效的代码块标记行（可能是开始或结束）
			
			# 4. 先把这一行之前的普通文本（如果有）刷新出去
			if line_start_idx > 0:
				var pre_fence_content: String = _pending_buffer.substr(0, line_start_idx)
				_append_content(pre_fence_content, p_instant)
				_pending_buffer = _pending_buffer.substr(line_start_idx)
				# 注意：此时 buffer 已被截断，开头即为（缩进 + ```），无需更新 fence_idx
				# 直接进入下一步处理这一行
			
			# 5. 检查这一行是否完整（是否有换行符）
			var newline_pos: int = _pending_buffer.find("\n")
			
			if newline_pos != -1:
				# 提取完整的一行（包含缩进、``` 和可能的语言标识符）
				var line_with_fence: String = _pending_buffer.substr(0, newline_pos)
				_pending_buffer = _pending_buffer.substr(newline_pos + 1) # 剩余部分留给下一次循环
				
				# 处理回车符兼容性
				if line_with_fence.ends_with("\r"):
					line_with_fence = line_with_fence.left(-1)
				
				# 交给解析器判断是“开始”还是“结束”
				_parse_fence_line(line_with_fence, p_instant)
				continue
			else:
				# 这一行还没传输完整（例如只收到了 "  ```gds"），等待下一个 chunk
				break
		else:
			# 6. 没有找到 ```，安全刷新缓冲区
			# 需要保留末尾可能的半个标记（如 "`" 或 "``"），防止被切断
			var safe_len: int = _pending_buffer.length()
			if _pending_buffer.ends_with("``"):
				safe_len -= 2
			elif _pending_buffer.ends_with("`"):
				safe_len -= 1
			
			if safe_len < _pending_buffer.length():
				# 有潜在的半个标记，只刷新前面的安全部分
				if safe_len > 0:
					var safe_part: String = _pending_buffer.left(safe_len)
					_append_content(safe_part, p_instant)
					_pending_buffer = _pending_buffer.right(-safe_len)
			else:
				# 没有潜在标记，全部刷新
				if not _pending_buffer.is_empty():
					_append_content(_pending_buffer, p_instant)
					_pending_buffer = ""
			
			break


# 解析包含 ``` 的特定行
func _parse_fence_line(p_line: String, p_instant: bool) -> void:
	if _current_state == ParseState.TEXT:
		var match_start: RegExMatch = _re_code_start.search(p_line)
		if match_start:
			_finish_typing()
			_current_state = ParseState.CODE
			_current_fence_str = match_start.get_string(1)
			var lang: String = match_start.get_string(2)
			_create_code_block(lang)
		else:
			_append_content(p_line + "\n", p_instant)
	
	elif _current_state == ParseState.CODE:
		var match_end: RegExMatch = _re_code_end.search(p_line)
		var is_closing: bool = false
		
		if match_end:
			var fence_found: String = match_end.get_string(1)
			# 结束围栏必须至少与开始围栏一样长
			if fence_found.length() >= _current_fence_str.length():
				is_closing = true
		
		if is_closing:
			_current_state = ParseState.TEXT
			_current_fence_str = ""
			_last_ui_node = null
			# 退出代码块时，当前行就是闭合行，所以下一行必然是新行
			_is_line_start = true
		else:
			_append_content(p_line + "\n", p_instant)


# 统一渲染入口
func _append_content(p_text: String, p_instant: bool) -> void:
	if p_text.is_empty(): return # 避免空字符串改变状态
	
	if _current_state == ParseState.CODE:
		_append_to_code(p_text)
	else:
		_append_to_text(p_text, p_instant)
	
	# 更新行首状态
	_is_line_start = p_text.ends_with("\n")


# 创建思考内容 UI 结构
func _create_reasoning_ui() -> void:
	_reasoning_container = FoldableContainer.new()
	_reasoning_container.name = "ReasoningContainer"
	_reasoning_container.set_title("🤔 Thinking Process")
	_reasoning_container.fold()
	
	_content_container.add_child(_reasoning_container)
	_content_container.move_child(_reasoning_container, 0)
	
	var margin: MarginContainer = MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	
	_reasoning_container.add_child(margin)
	_reasoning_label = RichTextLabel.new()
	_reasoning_label.bbcode_enabled = false
	_reasoning_label.fit_content = true
	_reasoning_label.selection_enabled = true
	_reasoning_label.modulate = Color(0.6, 0.6, 0.6)
	
	margin.add_child(_reasoning_label)
	_last_ui_node = null


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
		
		# 记录原始文本，防止多次点击导致逻辑混乱
		if copy_code_button.text != "Copied ✓":
			var original_text: String = "Copy"
			copy_code_button.text = "Copied ✓"
			copy_code_button.modulate = Color.GREEN_YELLOW
			
			# 等待 3 秒
			if copy_code_button.is_inside_tree():
				await copy_code_button.get_tree().create_timer(3.0).timeout
			
			# 恢复状态 (需检查节点是否仍有效)
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
	# 创建代码块后，意味着该行是围栏行，所以状态切换为 true (下一行必然是新行)
	_is_line_start = true


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
	var new_popuo_code_viewer_window: PopupCodeViewWindow = CODE_VIEWER_WINDOW_RES.instantiate()
	_current_popup_code_view_window = new_popuo_code_viewer_window
	# 添加到场景树
	add_child(_current_popup_code_view_window)
	
	_current_popup_code_view_window.get_ok_button().pressed.connect(func():
		remove_child(_current_popup_code_view_window)
		_current_popup_code_view_window.queue_free()
		_current_popup_code_view_window = null
		
		await get_tree().create_timer(1.0).timeout
		if is_instance_valid(new_popuo_code_viewer_window):
			AIChatLogger.debug("PopupCodeViewWindow Instance is still in Memory")
		else:
			AIChatLogger.debug("PopupCodeViewWindow Instance has been removed form Memory")
	)
	
	# 设置为可见
	_current_popup_code_view_window.visible = true
	# 设置代码内容
	var code_edit: CodeEdit = _current_popup_code_view_window.popup_code_edit
	code_edit.text = p_code_content
	# 弹出窗口
	_current_popup_code_view_window.popup_centered(Vector2i(800, 600))
