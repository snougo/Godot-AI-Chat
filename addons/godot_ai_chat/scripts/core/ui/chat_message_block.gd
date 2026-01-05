@tool
extends FoldableContainer
class_name ChatMessageBlock

# --- 场景引用 ---
@onready var content_container: VBoxContainer = $MarginContainer/VBoxContainer

# 预加载代码高亮主题
const SYNTAX_HIGHLIGHTER_RES: CodeHighlighter = preload("res://addons/godot_ai_chat/assets/code_hightlight.tres")

# --- 内部状态 ---
enum ParseState { TEXT, CODE }
var current_state: ParseState = ParseState.TEXT

# [核心] 混合缓冲区
# 只有当遇到潜在的 ``` 标记时，文本才会被暂时存入这里等待换行确认
var pending_buffer: String = ""

var last_ui_node: Control = null

# 正则匹配 (锚定行首)
var re_code_start: RegEx = RegEx.create_from_string("^```\\s*([a-zA-Z0-9_+\\-#.]*)\\s*$")
var re_code_end: RegEx = RegEx.create_from_string("^```\\s*$")

# 动态打字机状态
var typing_active: bool = false
var current_typing_node: RichTextLabel = null

# 工具调用展示节点
var _tool_rtl: RichTextLabel = null


func _ready() -> void:
	if not content_container:
		await get_tree().process_frame


# --- 公共接口 ---

func set_content(role: String, content: String, model_name: String = "", tool_calls: Array = []) -> void:
	_set_title(role, model_name)
	_clear_content()
	# 静态加载时，直接一次性处理，并在最后强制换行确保闭合
	_process_smart_chunk(content + "\n", true)
	
	# 静态加载历史中的工具调用
	for tc in tool_calls:
		show_tool_call(tc)


func start_stream(role: String, model_name: String = "") -> void:
	_set_title(role, model_name)
	_clear_content()
	visible = true


func append_chunk(text: String) -> void:
	if text.is_empty(): return
	_process_smart_chunk(text, false)


func finish_stream() -> void:
	# 强制刷新缓冲区里剩余的内容
	if not pending_buffer.is_empty():
		# 如果缓冲区里残留了 ``` 开头的内容（意味着最后一行没有换行符）
		# 我们需要尝试作为代码块标记解析它，以防是流的结束
		if pending_buffer.begins_with("```"):
			var line = pending_buffer
			if line.ends_with("\r"): 
				line = line.left(-1)
			_parse_fence_line(line, false)
		else:
			_append_content(pending_buffer, false)
		
		pending_buffer = ""
	
	# 如果打字机还在跑，让它瞬间跑完
	if typing_active and is_instance_valid(current_typing_node):
		current_typing_node.visible_characters = -1
		typing_active = false


func set_error(text: String) -> void:
	title = "❌ Error"
	_clear_content()
	var label = _create_text_block(text, true)
	label.modulate = Color(1, 0.4, 0.4)


func get_role() -> String:
	return get_meta("role") if has_meta("role") else ""


func show_tool_call(_tool_call: Dictionary) -> void:
	# 检查是否已经存在该 ID 的展示（防止流式多次重复创建 UI 节点）
	var call_id = _tool_call.get("id", "no-id")
	
	# 使用 meta 记录已显示的 call_id
	var shown_calls = content_container.get_meta("shown_calls", [])
	if call_id in shown_calls:
		_update_tool_call_ui(call_id, _tool_call)
		return
	
	shown_calls.append(call_id)
	content_container.set_meta("shown_calls", shown_calls)
	
	# 1. 创建外观容器 (PanelContainer)
	var panel = PanelContainer.new()
	panel.name = "Tool_" + call_id
	
	# 设置背景样式，使其看起来像一个控制台或代码块
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.12, 0.13, 0.16, 0.9) # 深色背景
	style.set_corner_radius_all(6)
	style.set_content_margin_all(10)
	style.border_width_left = 4
	style.border_color = Color.GOLD # 左侧金边提醒
	panel.add_theme_stylebox_override("panel", style)
	
	var vbox = VBoxContainer.new()
	panel.add_child(vbox)
	
	# 2. 标题：🔧 Tool Call: [工具名]
	var title_label = RichTextLabel.new()
	title_label.bbcode_enabled = true
	title_label.fit_content = true
	title_label.selection_enabled = false
	
	var tool_name = ""
	if _tool_call.has("function"):
		tool_name = _tool_call.function.get("name", "unknown")
	else:
		tool_name = _tool_call.get("name", "unknown")
	
	title_label.append_text("[b][color=cyan]🔧 Tool Call:[/color][/b] [color=yellow]%s[/color]" % tool_name)
	vbox.add_child(title_label)
	
	# 3. 参数详情 (RichTextLabel)
	var args_label = RichTextLabel.new()
	args_label.name = "ArgsLabel"
	args_label.bbcode_enabled = true
	args_label.fit_content = true
	#args_label.add_theme_font_size_override("normal_font_size", 20)
	vbox.add_child(args_label)
	
	_update_args_display(args_label, _tool_call)
	
	content_container.add_child(panel)
	
	# [重要] 重置 last_ui_node，确保工具调用后的普通文本会创建新的 RichTextLabel
	last_ui_node = null


# 在 chat_message_block.gd 中添加此方法，替换之前报错的部分

func display_image(data: PackedByteArray, mime: String) -> void:
	if data.is_empty(): return
	
	var img = Image.new()
	var err = OK
	
	# 根据 MIME 类型选择加载方式
	if mime == "image/png":
		err = img.load_png_from_buffer(data)
	elif mime == "image/jpeg" or mime == "image/jpg":
		err = img.load_jpg_from_buffer(data)
	elif mime == "image/webp":
		err = img.load_webp_from_buffer(data)
	elif mime == "image/svg+xml":
		err = img.load_svg_from_buffer(data)
	else:
		# 兜底：尝试作为 PNG 加载
		err = img.load_png_from_buffer(data)
	
	if err == OK:
		var tex = ImageTexture.create_from_image(img)
		var rect = TextureRect.new()
		rect.texture = tex
		rect.expand_mode = TextureRect.EXPAND_KEEP_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		
		# 限制预览图的最大高度，防止图片过大撑破 UI
		rect.custom_minimum_size = Vector2(0, 250) 
		
		content_container.add_child(rect)
		# 重置 last_ui_node，确保图片后的文字能正确开启新的 RichTextLabel
		last_ui_node = null
	else:
		push_error("Failed to load image buffer in ChatMessageBlock, error code: %d" % err)


# --- 核心渲染逻辑 ---

func _set_title(role: String, model_name: String) -> void:
	set_meta("role", role)
	match role:
		ChatMessage.ROLE_USER: title = "🧑‍💻 You"
		ChatMessage.ROLE_ASSISTANT: title = "🤖 Assistant" + ("/" + model_name if not model_name.is_empty() else "")
		ChatMessage.ROLE_TOOL: title = "⚙️ Tool Output"
		ChatMessage.ROLE_SYSTEM: title = "🔧 System"
		_: title = role.capitalize()


# 更新流式工具调用参数
func _update_tool_call_ui(call_id: String, tool_call: Dictionary) -> void:
	var panel = content_container.get_node_or_null("Tool_" + call_id)
	if panel:
		var args_label = panel.find_child("ArgsLabel", true, false)
		if args_label:
			_update_args_display(args_label, tool_call)


# 解析并格式化参数显示
func _update_args_display(label: RichTextLabel, tool_call: Dictionary) -> void:
	var args_str = ""
	if tool_call.has("function"):
		args_str = tool_call.function.get("arguments", "")
	else:
		args_str = str(tool_call.get("arguments", ""))
	
	label.clear()
	label.push_color(Color(0.7, 0.7, 0.7))
	if args_str.strip_edges().begins_with("{"):
		# 尝试美化 JSON，如果失败则原样显示
		var parsed = JSON.parse_string(args_str)
		if parsed != null:
			label.add_text(JSON.stringify(parsed, "  "))
		else:
			label.add_text(args_str)
	else:
		label.add_text(args_str)
	label.pop()


func _clear_content() -> void:
	for c in content_container.get_children():
		c.queue_free()
	
	# 重置已显示的工具调用记录，防止内容刷新时逻辑冲突
	if content_container.has_meta("shown_calls"):
		content_container.set_meta("shown_calls", [])
	
	current_state = ParseState.TEXT
	pending_buffer = ""
	last_ui_node = null
	typing_active = false
	current_typing_node = null
	_tool_rtl = null


# [核心逻辑] 智能分块处理
func _process_smart_chunk(incoming_text: String, instant: bool) -> void:
	# 1. 拼接到待处理缓冲区
	pending_buffer += incoming_text
	
	# 2. 循环处理缓冲区，直到没有完整的"关键帧"为止
	while true:
		# 搜索反引号（这是唯一的阻断符）
		var fence_idx = pending_buffer.find("```")
		
		if fence_idx != -1:
			# A. 发现了完整的标记
			
			# A1. 先把反引号之前的内容（安全区）渲染出来
			if fence_idx > 0:
				var safe_part = pending_buffer.substr(0, fence_idx)
				_append_content(safe_part, instant)
				# 缓冲区切除安全部分，现在的 buffer 以 ``` 开头
				pending_buffer = pending_buffer.substr(fence_idx)
			
			# A2. 检查这个 ``` 所在的一行是否已经完整（即是否有换行符）
			var newline_pos = pending_buffer.find("\n")
			
			if newline_pos != -1:
				# 找到了换行，提取这一行进行判定
				var line_with_fence = pending_buffer.substr(0, newline_pos) # 不含 \n
				
				# 从缓冲区移除这一行 (含 \n)
				pending_buffer = pending_buffer.substr(newline_pos + 1)
				
				# 兼容 Windows 换行
				if line_with_fence.ends_with("\r"):
					line_with_fence = line_with_fence.left(-1)
				
				# A3. 解析这一行
				_parse_fence_line(line_with_fence, instant)
				
				# 继续循环处理剩余 buffer (因为可能一个 chunk 里包含多个块)
				continue
			else:
				# 还没有换行，我们无法判断这是代码块标记还是普通文本
				# 暂停处理，等待下一个 chunk 带来换行符
				break
		
		else:
			# B. 没有发现完整的
			# B1. 检查末尾是否有潜在的半个标记 (` ` 或 ` `` `)
			# 我们不能把这两个字符渲染出去，因为它们可能是未来 ``` 的一部分
			var safe_len = pending_buffer.length()
			if pending_buffer.ends_with("``"):
				safe_len -= 2
			elif pending_buffer.ends_with("`"):
				safe_len -= 1
			
			if safe_len < pending_buffer.length():
				# B2. 有潜在标记，保留尾部，只渲染前面的安全部分
				if safe_len > 0:
					var safe_part = pending_buffer.left(safe_len)
					_append_content(safe_part, instant)
					pending_buffer = pending_buffer.right(-safe_len)
				# 剩下的潜在标记留给下一帧处理
			else:
				# B3. 完全安全，没有反引号干扰
				if not pending_buffer.is_empty():
					_append_content(pending_buffer, instant)
					pending_buffer = ""
			
			# 本轮处理结束，等待更多数据
			break



# 解析包含 ``` 的特定行
func _parse_fence_line(line: String, instant: bool) -> void:
	if current_state == ParseState.TEXT:
		# 尝试匹配代码块开始
		var match_start = re_code_start.search(line)
		if match_start:
			# 是代码块开始 -> 切换状态，创建编辑器，消耗该行
			current_state = ParseState.CODE
			var lang = match_start.get_string(1)
			_create_code_block(lang)
		else:
			# 只是包含 ``` 的普通文本（比如行内代码）-> 原样渲染
			_append_content(line + "\n", instant)
			
	elif current_state == ParseState.CODE:
		# 尝试匹配代码块结束
		var match_end = re_code_end.search(line)
		if match_end:
			# 是代码块结束 -> 切换状态，消耗该行
			current_state = ParseState.TEXT
			last_ui_node = null # 重置，下次 text 会创建新 label
		else:
			# 是包含 ``` 的代码内容 -> 追加到代码块
			_append_content(line + "\n", instant)


# 统一渲染入口
func _append_content(text: String, instant: bool) -> void:
	if current_state == ParseState.CODE:
		_append_to_code(text)
	else:
		_append_to_text(text, instant)


# --- 具体的 UI 操作 ---

func _create_code_block(lang: String) -> void:
	var code_edit = CodeEdit.new()
	code_edit.editable = false
	code_edit.syntax_highlighter = SYNTAX_HIGHLIGHTER_RES
	code_edit.scroll_fit_content_height = true
	code_edit.draw_tabs = true
	code_edit.gutters_draw_line_numbers = true
	code_edit.minimap_draw = false
	code_edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	code_edit.mouse_filter = Control.MOUSE_FILTER_PASS
	
	content_container.add_child(code_edit)
	last_ui_node = code_edit
	
	# 标题栏
	var header = HBoxContainer.new()
	var lang_label = Label.new()
	lang_label.text = lang if not lang.is_empty() else "Code"
	lang_label.modulate = Color(0.7, 0.7, 0.7)
	var copy_btn = Button.new()
	copy_btn.text = "Copy"
	copy_btn.flat = true
	copy_btn.focus_mode = Control.FOCUS_NONE
	copy_btn.pressed.connect(func(): DisplayServer.clipboard_set(code_edit.text))
	header.add_child(lang_label)
	header.add_child(Control.new())
	header.get_child(1).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(copy_btn)
	
	content_container.move_child(code_edit, content_container.get_child_count() - 1)
	content_container.add_child(header)
	content_container.move_child(header, content_container.get_child_count() - 2)


func _append_to_code(text: String) -> void:
	if last_ui_node is CodeEdit:
		last_ui_node.text += text


func _append_to_text(text: String, instant: bool) -> void:
	if not last_ui_node is RichTextLabel:
		last_ui_node = _create_text_block("", instant)
	
	if instant:
		last_ui_node.text += text
	else:
		# 锁定当前显示进度
		var old_total = last_ui_node.get_total_character_count()
		if last_ui_node.visible_characters == -1:
			last_ui_node.visible_characters = old_total
		
		# 追加物理文本
		last_ui_node.text += text
		
		# 启动/接管动态打字机
		_trigger_typewriter(last_ui_node)


func _create_text_block(initial_text: String, instant: bool) -> RichTextLabel:
	var rtl = RichTextLabel.new()
	rtl.bbcode_enabled = true
	rtl.text = initial_text
	rtl.fit_content = true
	rtl.selection_enabled = true
	rtl.focus_mode = Control.FOCUS_CLICK
	if not instant:
		rtl.visible_characters = 0
	content_container.add_child(rtl)
	return rtl


# --- [核心] 动态变速打字机 ---

func _trigger_typewriter(node: RichTextLabel) -> void:
	current_typing_node = node
	if not typing_active:
		typing_active = true
		_typewriter_loop()

func _typewriter_loop() -> void:
	# 1. 安全检查
	if not typing_active or not is_instance_valid(current_typing_node):
		typing_active = false
		return
	
	# 2. 计算堆积量 (Lag)
	var total = current_typing_node.get_total_character_count()
	var current = current_typing_node.visible_characters
	
	# 如果是 -1，说明已经全显了
	if current == -1:
		current = total
	
	var lag = total - current
	
	# 3. 结束条件
	if lag <= 0:
		current_typing_node.visible_characters = -1
		typing_active = false
		return
	
	# 4. 动态计算步长 (Step)
	# 堆积越多，跑得越快
	var step: int = 1
	if lag > 100: step = 20    # 极速：大量代码或文本粘贴
	elif lag > 50: step = 10   # 快速
	elif lag > 20: step = 5    # 中速
	elif lag > 5: step = 2     # 慢速加速
	else: step = 1             # 正常逐字
	
	# 5. 执行更新
	current_typing_node.visible_characters += step
	
	# 6. 循环 (约 60FPS)
	get_tree().create_timer(0.016).timeout.connect(_typewriter_loop)
