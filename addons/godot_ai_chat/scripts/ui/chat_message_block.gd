@tool
class_name ChatMessageBlock
extends FoldableContainer

## 负责单条消息的 UI 渲染，支持 Markdown 解析、代码高亮、打字机效果和工具调用展示。

# --- Enums ---

## 解析状态
enum ParseState { 
	TEXT, ## 正在解析普通文本
	CODE  ## 正在解析代码块
}

# --- Constants ---

## 预加载代码高亮主题
const SYNTAX_HIGHLIGHTER_RES: CodeHighlighter = preload("res://addons/godot_ai_chat/assets/code_hightlight.tres")

# --- @onready Vars ---

@onready var _content_container: VBoxContainer = $MarginContainer/VBoxContainer

# --- Private Vars ---

var _current_state: ParseState = ParseState.TEXT

## 混合缓冲区：只有当遇到潜在的 ``` 标记时，文本才会被暂时存入这里等待换行确认
var _pending_buffer: String = ""

## 记录上一个创建的 UI 节点，用于连续追加内容
var _last_ui_node: Control = null

## 正则匹配：代码块开始 (锚定行首，但是允许行首出现空格)
var _re_code_start: RegEx = RegEx.create_from_string("^\\s*```\\s*(.*)\\s*$")

## 正则匹配：代码块结束 (锚定行首，但是允许行首出现空格)
#var _re_code_end: RegEx = RegEx.create_from_string("^```\\s*$")
var _re_code_end: RegEx = RegEx.create_from_string("^\\s*```\\s*$")

## 打字机状态
var _typing_active: bool = false
## 当前正在执行打字机效果的节点
var _current_typing_node: RichTextLabel = null

## 思考内容 UI 引用
var _reasoning_container: FoldableContainer = null
var _reasoning_label: RichTextLabel = null

# [新增] 专门用于处理 <think> 标签的缓冲区和状态
var _think_parse_buffer: String = ""
var _is_parsing_think: bool = false

# --- Built-in Functions ---

func _ready() -> void:
	if not _content_container:
		await get_tree().process_frame

# --- Public Functions ---

## 设置消息内容（静态加载）
## [param _role]: 消息角色
## [param _content]: 消息正文
## [param _model_name]: 模型名称
## [param _tool_calls]: 工具调用列表
## [param _reasoning]: 思考内容
func set_content(_role: String, _content: String, _model_name: String = "", _tool_calls: Array = [], _reasoning: String = "") -> void:
	_set_title(_role, _model_name)
	_clear_content()
	
	if not _reasoning.is_empty():
		append_reasoning(_reasoning)
	
	# 静态加载时，直接一次性处理，并在最后强制换行确保闭合
	_process_smart_chunk(_content + "\n", true)
	
	for _tc in _tool_calls:
		show_tool_call(_tc)


## 开始流式接收消息
func start_stream(_role: String, _model_name: String = "") -> void:
	_set_title(_role, _model_name)
	_clear_content()
	visible = true


## 追加流式文本块
func append_chunk(_text: String) -> void:
	if _text.is_empty(): 
		return
	
	_think_parse_buffer += _text
	
	while true:
		if _is_parsing_think:
			var _end_idx: int = _think_parse_buffer.find("</think>")
			if _end_idx != -1:
				# 思考结束
				var _think_content: String = _think_parse_buffer.substr(0, _end_idx)
				append_reasoning(_think_content)
				
				_is_parsing_think = false
				_think_parse_buffer = _think_parse_buffer.substr(_end_idx + 8)
				continue
			else:
				# 还没结束，尽量刷新缓冲区到思考UI，只留一点尾巴防止切断 </think>
				var _keep_len: int = 8 # </think> 长度
				if _think_parse_buffer.length() > _keep_len:
					var _flush_len: int = _think_parse_buffer.length() - _keep_len
					var _content: String = _think_parse_buffer.left(_flush_len)
					append_reasoning(_content)
					_think_parse_buffer = _think_parse_buffer.right(-_flush_len)
				break
		
		else: # 正常文本模式
			var _start_idx: int = _think_parse_buffer.find("<think>")
			if _start_idx != -1:
				# 发现思考开始
				# 1. 先把 <think> 之前的内容当作普通文本处理
				if _start_idx > 0:
					var _normal_text: String = _think_parse_buffer.substr(0, _start_idx)
					_process_smart_chunk(_normal_text, false) # 调用原有的处理逻辑
				
				# 2. 切换状态
				_is_parsing_think = true
				_think_parse_buffer = _think_parse_buffer.substr(_start_idx + 7)
				continue
			else:
				# 没发现 <think>，检查是否有潜在的半个 <think>
				# 类似 <, <t, <th ...
				var _safe_idx: int = _think_parse_buffer.length()
				# 简单粗暴点：如果不包含 <，则全部安全
				# 如果包含 <，则保留 < 及其后面的内容到下次处理
				var _last_lt: int = _think_parse_buffer.rfind("<")
				if _last_lt != -1:
					# 检查后面是否可能构成 <think>
					var _potential: String = _think_parse_buffer.substr(_last_lt)
					if "<think>".begins_with(_potential):
						_safe_idx = _last_lt
				
				if _safe_idx > 0:
					var _safe_text: String = _think_parse_buffer.left(_safe_idx)
					_process_smart_chunk(_safe_text, false) # 调用原有的处理逻辑
					_think_parse_buffer = _think_parse_buffer.right(-_safe_idx)
				
				break


## 追加流式思考内容
func append_reasoning(_text: String) -> void:
	if _text.is_empty(): 
		return
	
	if not is_instance_valid(_reasoning_container):
		_create_reasoning_ui()
	
	if is_instance_valid(_reasoning_label):
		_reasoning_label.text += _text


## 结束流式接收，刷新缓冲区
func finish_stream() -> void:
	# 刷新剩余的缓冲区
	if not _think_parse_buffer.is_empty():
		if _is_parsing_think:
			append_reasoning(_think_parse_buffer)
		else:
			_process_smart_chunk(_think_parse_buffer, false)
	_think_parse_buffer = ""
	_is_parsing_think = false
	
	if not _pending_buffer.is_empty():
		if _pending_buffer.begins_with("```"):
			var _line: String = _pending_buffer
			if _line.ends_with("\r"): 
				_line = _line.left(-1)
			_parse_fence_line(_line, false)
		else:
			_append_content(_pending_buffer, false)
		
		_pending_buffer = ""
	
	_finish_typing()


## 设置错误信息显示
func set_error(_text: String) -> void:
	title = "❌ Error"
	_clear_content()
	var _label: RichTextLabel = _create_text_block(_text, true)
	_label.modulate = Color(1, 0.4, 0.4)


## 获取当前消息的角色
func get_role() -> String:
	return get_meta("role") if has_meta("role") else ""


## 展示工具调用详情
func show_tool_call(_tool_call: Dictionary) -> void:
	var _call_id: String = _tool_call.get("id", "no-id")
	var _safe_node_name: String = ("Tool_" + _call_id).validate_node_name()
	
	var _shown_calls: Array = _content_container.get_meta("shown_calls", [])
	if _call_id in _shown_calls:
		_update_tool_call_ui(_safe_node_name, _tool_call)
		return
	
	_shown_calls.append(_call_id)
	_content_container.set_meta("shown_calls", _shown_calls)
	
	# 1. 创建外观容器
	var _panel: PanelContainer = PanelContainer.new()
	_panel.name = _safe_node_name
	
	var _style: StyleBoxFlat = StyleBoxFlat.new()
	_style.bg_color = Color(0.12, 0.13, 0.16, 0.9)
	_style.set_corner_radius_all(6)
	_style.set_content_margin_all(10)
	_style.border_width_left = 4
	_style.border_color = Color.GOLD
	_panel.add_theme_stylebox_override("panel", _style)
	
	var _vbox: VBoxContainer = VBoxContainer.new()
	_panel.add_child(_vbox)
	
	# 2. 标题
	var _title_label: RichTextLabel = RichTextLabel.new()
	_title_label.bbcode_enabled = true
	_title_label.fit_content = true
	_title_label.selection_enabled = false
	
	var _tool_name: String = ""
	if _tool_call.has("function"):
		_tool_name = _tool_call.function.get("name", "unknown")
	else:
		_tool_name = _tool_call.get("name", "unknown")
	
	_title_label.append_text("[b][color=cyan]🔧 Tool Call:[/color][/b] [color=yellow]%s[/color]" % _tool_name)
	_vbox.add_child(_title_label)
	
	# 3. 参数详情
	var _args_label: RichTextLabel = RichTextLabel.new()
	_args_label.name = "ArgsLabel"
	_args_label.bbcode_enabled = true
	_args_label.fit_content = true
	_vbox.add_child(_args_label)
	
	_update_args_display(_args_label, _tool_call)
	
	_content_container.add_child(_panel)
	_last_ui_node = null


## 显示图片内容
func display_image(_data: PackedByteArray, _mime: String) -> void:
	if _data.is_empty(): 
		return
	
	var _img: Image = Image.new()
	var _err: Error = OK
	
	match _mime:
		"image/png": _err = _img.load_png_from_buffer(_data)
		"image/jpeg", "image/jpg": _err = _img.load_jpg_from_buffer(_data)
		"image/webp": _err = _img.load_webp_from_buffer(_data)
		"image/svg+xml": _err = _img.load_svg_from_buffer(_data)
		_: _err = _img.load_png_from_buffer(_data)
	
	if _err == OK:
		var _tex: ImageTexture = ImageTexture.create_from_image(_img)
		var _rect: TextureRect = TextureRect.new()
		_rect.texture = _tex
		_rect.expand_mode = TextureRect.EXPAND_KEEP_SIZE
		_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_rect.custom_minimum_size = Vector2(0, 250) 
		
		_content_container.add_child(_rect)
		_last_ui_node = null
	else:
		push_error("Failed to load image buffer in ChatMessageBlock, error code: %d" % _err)

# --- Private Functions ---

## 设置标题和角色元数据
func _set_title(_role: String, _model_name: String) -> void:
	set_meta("role", _role)
	match _role:
		ChatMessage.ROLE_USER: 
			title = "🧑‍💻 You"
			if is_folded(): expand() 
		
		ChatMessage.ROLE_ASSISTANT: 
			title = "🤖 Assistant" + ("/" + _model_name if not _model_name.is_empty() else "")
			if is_folded(): expand()
		
		ChatMessage.ROLE_TOOL: 
			title = "⚙️ Tool Output"
			if not is_folded(): fold()
		
		ChatMessage.ROLE_SYSTEM: 
			title = "🔧 System"
			if not is_folded(): fold()
		
		_: 
			title = _role.capitalize()
			if is_folded(): expand()


## 更新流式工具调用参数 UI
func _update_tool_call_ui(_node_name: String, _tool_call: Dictionary) -> void:
	var _panel: Node = _content_container.get_node_or_null(_node_name)
	if _panel:
		var _args_label: RichTextLabel = _panel.find_child("ArgsLabel", true, false)
		if _args_label:
			_update_args_display(_args_label, _tool_call)


## 解析并格式化参数显示
func _update_args_display(_label: RichTextLabel, _tool_call: Dictionary) -> void:
	var _args_str: String = ""
	if _tool_call.has("function"):
		_args_str = _tool_call.function.get("arguments", "")
	else:
		_args_str = str(_tool_call.get("arguments", ""))
	
	_label.clear()
	_label.push_color(Color(0.7, 0.7, 0.7))
	
	if _args_str.strip_edges().begins_with("{"):
		var _json_obj: JSON = JSON.new()
		var _err: Error = _json_obj.parse(_args_str)
		
		if _err == OK:
			_label.add_text(JSON.stringify(_json_obj.data, "  "))
		else:
			_label.add_text(_args_str)
	else:
		_label.add_text(_args_str)
	
	_label.pop()


## 清空所有内容
func _clear_content() -> void:
	for _c in _content_container.get_children():
		_c.queue_free()
	
	if _content_container.has_meta("shown_calls"):
		_content_container.set_meta("shown_calls", [])
	
	_current_state = ParseState.TEXT
	_pending_buffer = ""
	_last_ui_node = null
	_typing_active = false
	_current_typing_node = null
	_reasoning_container = null
	_reasoning_label = null


## 智能分块处理逻辑
## 核心职责：在流式传输中检测 Markdown 代码块标记（```），解决缩进导致的解析错误
func _process_smart_chunk(_incoming_text: String, _instant: bool) -> void:
	_pending_buffer += _incoming_text
	
	while true:
		# 1. 查找缓冲区中是否存在代码块标记
		var _fence_idx: int = _pending_buffer.find("```")
		
		if _fence_idx != -1:
			# 2. 回溯检查：判断 ``` 之前是否只有空白字符（空格/制表符）
			# 这是为了支持缩进的代码块（例如 "  ```gdscript"）
			var _line_start_idx: int = -1
			var _is_valid_fence: bool = false
			var _ptr: int = _fence_idx - 1
			
			while _ptr >= 0:
				var _char: String = _pending_buffer[_ptr]
				if _char == '\n':
					# 找到上一个换行符，确认是新的一行
					_line_start_idx = _ptr + 1
					_is_valid_fence = true
					break
				elif _char == ' ' or _char == '\t':
					# 允许空白字符，继续回溯
					_ptr -= 1
				else:
					# 遇到非空白字符（如 "abc ```"），说明不是行首标记
					_is_valid_fence = false
					break
			
			if _ptr < 0: # 回溯到了 buffer 开头，说明是第一行且符合条件
				_line_start_idx = 0
				_is_valid_fence = true
			
			# 3. 分支处理：无效标记 vs 有效标记
			if not _is_valid_fence:
				# 情况 A: 标记前有杂质，视为普通文本
				# 将 ``` 及其之前的部分作为文本追加，然后继续处理剩余部分
				var _safe_len: int = _fence_idx + 3
				var _safe_part: String = _pending_buffer.substr(0, _safe_len)
				_append_content(_safe_part, _instant)
				_pending_buffer = _pending_buffer.substr(_safe_len)
				continue
			
			# 情况 B: 是有效的代码块标记行（可能是开始或结束）
			
			# 4. 先把这一行之前的普通文本（如果有）刷新出去
			if _line_start_idx > 0:
				var _pre_fence_content: String = _pending_buffer.substr(0, _line_start_idx)
				_append_content(_pre_fence_content, _instant)
				_pending_buffer = _pending_buffer.substr(_line_start_idx)
				# 注意：此时 buffer 已被截断，开头即为（缩进 + ```），无需更新 _fence_idx
				# 直接进入下一步处理这一行
			
			# 5. 检查这一行是否完整（是否有换行符）
			var _newline_pos: int = _pending_buffer.find("\n")
			
			if _newline_pos != -1:
				# 提取完整的一行（包含缩进、``` 和可能的语言标识符）
				var _line_with_fence: String = _pending_buffer.substr(0, _newline_pos)
				_pending_buffer = _pending_buffer.substr(_newline_pos + 1) # 剩余部分留给下一次循环
				
				# 处理回车符兼容性
				if _line_with_fence.ends_with("\r"):
					_line_with_fence = _line_with_fence.left(-1)
				
				# 交给解析器判断是“开始”还是“结束”
				_parse_fence_line(_line_with_fence, _instant)
				continue
			else:
				# 这一行还没传输完整（例如只收到了 "  ```gds"），等待下一个 chunk
				break
		else:
			# 6. 没有找到 ```，安全刷新缓冲区
			# 需要保留末尾可能的半个标记（如 "`" 或 "``"），防止被切断
			var _safe_len: int = _pending_buffer.length()
			if _pending_buffer.ends_with("``"):
				_safe_len -= 2
			elif _pending_buffer.ends_with("`"):
				_safe_len -= 1
			
			if _safe_len < _pending_buffer.length():
				# 有潜在的半个标记，只刷新前面的安全部分
				if _safe_len > 0:
					var _safe_part: String = _pending_buffer.left(_safe_len)
					_append_content(_safe_part, _instant)
					_pending_buffer = _pending_buffer.right(-_safe_len)
			else:
				# 没有潜在标记，全部刷新
				if not _pending_buffer.is_empty():
					_append_content(_pending_buffer, _instant)
					_pending_buffer = ""
			break


## 解析包含 ``` 的特定行
func _parse_fence_line(_line: String, _instant: bool) -> void:
	if _current_state == ParseState.TEXT:
		var _match_start: RegExMatch = _re_code_start.search(_line)
		if _match_start:
			_finish_typing()
			_current_state = ParseState.CODE
			var _lang: String = _match_start.get_string(1)
			_create_code_block(_lang)
		else:
			_append_content(_line + "\n", _instant)
			
	elif _current_state == ParseState.CODE:
		var _match_end: RegExMatch = _re_code_end.search(_line)
		if _match_end:
			_current_state = ParseState.TEXT
			_last_ui_node = null
		else:
			_append_content(_line + "\n", _instant)


## 统一渲染入口
func _append_content(_text: String, _instant: bool) -> void:
	if _current_state == ParseState.CODE:
		_append_to_code(_text)
	else:
		_append_to_text(_text, _instant)


## 创建思考内容 UI 结构
func _create_reasoning_ui() -> void:
	_reasoning_container = FoldableContainer.new()
	_reasoning_container.name = "ReasoningContainer"
	_reasoning_container.set_title("🤔 Thinking Process")
	_reasoning_container.fold()
	
	_content_container.add_child(_reasoning_container)
	_content_container.move_child(_reasoning_container, 0)
	
	var _margin: MarginContainer = MarginContainer.new()
	_margin.add_theme_constant_override("margin_left", 12)
	_margin.add_theme_constant_override("margin_right", 12)
	_margin.add_theme_constant_override("margin_bottom", 12)
	_reasoning_container.add_child(_margin)
	
	_reasoning_label = RichTextLabel.new()
	_reasoning_label.bbcode_enabled = false
	_reasoning_label.fit_content = true
	_reasoning_label.selection_enabled = true
	_reasoning_label.modulate = Color(0.6, 0.6, 0.6)
	_margin.add_child(_reasoning_label)
	
	_last_ui_node = null


## 创建代码块 UI
func _create_code_block(_lang: String) -> void:
	_finish_typing()
	
	var _code_edit: CodeEdit = CodeEdit.new()
	_code_edit.editable = false
	_code_edit.syntax_highlighter = SYNTAX_HIGHLIGHTER_RES
	_code_edit.scroll_fit_content_height = true
	_code_edit.draw_tabs = true
	_code_edit.gutters_draw_line_numbers = true
	_code_edit.minimap_draw = false
	_code_edit.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_code_edit.mouse_filter = Control.MOUSE_FILTER_PASS
	
	_content_container.add_child(_code_edit)
	_last_ui_node = _code_edit
	
	var _header: HBoxContainer = HBoxContainer.new()
	var _lang_label: Label = Label.new()
	_lang_label.text = _lang if not _lang.is_empty() else "Code"
	_lang_label.modulate = Color(0.7, 0.7, 0.7)
	
	var _copy_btn: Button = Button.new()
	_copy_btn.text = "Copy"
	_copy_btn.flat = true
	_copy_btn.focus_mode = Control.FOCUS_NONE
	#_copy_btn.pressed.connect(func(): DisplayServer.clipboard_set(_code_edit.text))
	# --- [修改开始] 增强的复制反馈逻辑 ---
	_copy_btn.pressed.connect(func():
		DisplayServer.clipboard_set(_code_edit.text)
		
		# 记录原始文本，防止多次点击导致逻辑混乱
		if _copy_btn.text != "Copied ✓":
			var _original_text: String = "Copy"
			_copy_btn.text = "Copied ✓"
			_copy_btn.modulate = Color.GREEN_YELLOW # 可选：稍微变色提示
			
			# 等待 3 秒
			if _copy_btn.is_inside_tree():
				await _copy_btn.get_tree().create_timer(3.0).timeout
			
			# 恢复状态 (需检查节点是否仍有效)
			if is_instance_valid(_copy_btn):
				_copy_btn.text = _original_text
				_copy_btn.modulate = Color.WHITE
	)
	# --- [修改结束] ---
	
	_header.add_child(_lang_label)
	_header.add_child(Control.new())
	_header.get_child(1).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.add_child(_copy_btn)
	
	_content_container.move_child(_code_edit, _content_container.get_child_count() - 1)
	_content_container.add_child(_header)
	_content_container.move_child(_header, _content_container.get_child_count() - 2)


## 追加内容到代码块
func _append_to_code(_text: String) -> void:
	if _last_ui_node is CodeEdit:
		#_last_ui_node.text += _text
		# 使用 insert_text_at_caret 替代 text +=
		_last_ui_node.insert_text_at_caret(_text)


## 追加内容到文本块
func _append_to_text(_text: String, _instant: bool) -> void:
	if not _last_ui_node is RichTextLabel:
		_finish_typing()
		_last_ui_node = _create_text_block("", _instant)
	
	var _safe_text: String = _text.replace("[", "[lb]")
	
	if _instant:
		_last_ui_node.text += _text
	else:
		var _old_total: int = _last_ui_node.get_total_character_count()
		if _last_ui_node.visible_characters == -1:
			_last_ui_node.visible_characters = _old_total
		
		_last_ui_node.text += _text
		_trigger_typewriter(_last_ui_node)


## 创建文本块 UI
func _create_text_block(_initial_text: String, _instant: bool) -> RichTextLabel:
	var _rtl: RichTextLabel = RichTextLabel.new()
	_rtl.bbcode_enabled = true
	_rtl.text = _initial_text
	_rtl.fit_content = true
	_rtl.selection_enabled = true
	_rtl.focus_mode = Control.FOCUS_CLICK
	if not _instant:
		_rtl.visible_characters = 0
	_content_container.add_child(_rtl)
	return _rtl


## 触发打字机效果
func _trigger_typewriter(_node: RichTextLabel) -> void:
	_current_typing_node = _node
	if not _typing_active:
		_typing_active = true
		_typewriter_loop()


## 强制结束打字机效果
func _finish_typing() -> void:
	if _typing_active and is_instance_valid(_current_typing_node):
		_current_typing_node.visible_characters = -1
		_typing_active = false


## 打字机循环逻辑
func _typewriter_loop() -> void:
	if not _typing_active or not is_instance_valid(_current_typing_node):
		_typing_active = false
		return
	
	var _total: int = _current_typing_node.get_total_character_count()
	var _current: int = _current_typing_node.visible_characters
	
	if _current == -1:
		_current = _total
	
	var _lag: int = _total - _current
	
	if _lag <= 0:
		_current_typing_node.visible_characters = -1
		_typing_active = false
		return
	
	var _step: int = 1
	if _lag > 100: _step = 20
	elif _lag > 50: _step = 10
	elif _lag > 20: _step = 5
	elif _lag > 5: _step = 2
	else: _step = 1
	
	_current_typing_node.visible_characters += _step
	
	get_tree().create_timer(0.016).timeout.connect(_typewriter_loop)
