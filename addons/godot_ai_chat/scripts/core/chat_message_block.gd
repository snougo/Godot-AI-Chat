@tool
extends FoldableContainer
class_name ChatMessageBlock


# 预加载代码高亮主题资源，用于CodeEdit节点。
const SYNTAX_HIGHLIGHTER_RES: CodeHighlighter = preload("res://addons/godot_ai_chat/assets/code_hightlight.tres")

# 内部解析状态机，用于区分当前正在处理的是普通文本还是代码块。
enum _ParseState {
	IN_TEXT, # 正在解析普通文本内容
	IN_CODE  # 正在解析代码块内容
}

@onready var content_container: VBoxContainer = $MarginContainer/VBoxContainer

# --- 状态机与解析 ---
# 当前的解析状态。
var current_parse_state: _ParseState = _ParseState.IN_TEXT
# 用于精确匹配代码块结束标记的字符（` 或 ~），确保开始和结束标记类型一致。
var code_fence_char: String = ""
# 用于精确匹配代码块结束标记的长度，确保开始和结束标记长度一致。
var code_fence_len: int = 0
# 用于匹配代码块开启的正则表达式 (例如 ```)。
var re_fence_open: RegEx = RegEx.create_from_string("^\\s*([`~]{3,})")
# 用于匹配代码块关闭的正则表达式。
var re_fence_close: RegEx = RegEx.create_from_string("^\\s*([`~]{3,})\\s*$")

# --- 缓冲机制 ---
# 用于累积字符，直到形成完整的一行。当解析器处于代码模式或怀疑某行是代码标记时激活。
var line_buffer: String = ""
# 跟踪最后一个UI节点（RichTextLabel或CodeEdit），以便进行增量追加，避免创建过多节点。
var last_ui_node = null
# 标记下一个接收的字符是否是新一行的开始。
var is_start_of_line: bool = true
# 标记当前是否正在为潜在的代码块标记进行行缓冲。
var is_buffering_potential_code_line: bool = false

# --- 打字机效果 ---
# 打字机效果的时间累加器。
var typewriter_accumulator: float = 0.0
# 打字机效果的速度（每秒显示的字符数）。
#var typewriter_speed: float = 200.0
# 基础打字速度（每秒字符数），这是在没有文本积压时的正常速度。
@export var base_typewriter_speed: float = 50.0
# 加速因子。积压的每个字符会使速度增加这个值。例如，0.5表示每积压10个字符，速度会增加5。
@export var acceleration_factor: float = 2.0
# 速度上限（每秒字符数），防止速度过快导致瞬间完成，失去打字机效果。
@export var max_typewriter_speed: float = 3000.0


func _process(_delta: float) -> void:
	# 如果最后一个节点不是一个有效的RichTextLabel实例，则不执行打字机逻辑。
	if not is_instance_valid(last_ui_node) or not last_ui_node is RichTextLabel:
		return
	
	var rtf: RichTextLabel = last_ui_node
	var total_chars: int = rtf.get_total_character_count()
	
	# 如果可见字符数小于总字符数，则继续逐字显示动画。
	if rtf.visible_characters < total_chars:
		typewriter_accumulator += _delta
		
		# 动态计算打字机速度
		# 1. 计算积压的字符数（总字符数 - 已显示字符数）
		var lag_chars: int = total_chars - rtf.visible_characters
		# 2. 根据积压字符数和加速因子计算目标速度
		var target_speed: float = base_typewriter_speed + (lag_chars * acceleration_factor)
		# 3. 将速度限制在设定的最大值内
		var dynamic_speed: float = min(target_speed, max_typewriter_speed)
		# 4. 使用动态计算出的速度来决定本帧需要增加多少字符
		var chars_to_add: int = floor(typewriter_accumulator * dynamic_speed)
		
		if chars_to_add > 0:
			rtf.visible_characters = min(rtf.visible_characters + chars_to_add, total_chars)
			# 注意：这里要用回 dynamic_speed 来计算消耗的时间，保持一致性
			typewriter_accumulator -= chars_to_add / dynamic_speed
	else:
		# 如果已经全部显示，重置累加器，避免不必要的计算。
		typewriter_accumulator = 0.0


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 异步设置内容并立即显示
func set_message_block_context_async(_role: String, _content: String, _model_name: String = "") -> void:
	_set_message_block_title(_role, _model_name)
	_message_block_context_clean()
	# 调用新的内部异步渲染函数，并传递 true 表示需要即时显示
	await _render_content_by_line_async(_content, true)
	# 确保处理完所有缓冲内容
	flush_assistant_stream_output()

# 用于初始化一个全新的消息块，例如用户消息或加载历史记录时。
func set_message_block(_role: String, _content: String, _model_name: String = "") -> void:
	_set_message_block_title(_role, _model_name)
	# 对于一次性设置的内容，直接重绘整个显示区域。
	# 因为只执行一次，性能不是主要问题。
	_redraw_display_from_full_content(_content)


# 此方法专门用于显示来自 "tool" 角色的、可能导致UI冻结的大量文本。
# 它会立即设置好标题，然后启动一个异步任务来逐行渲染内容。
func set_tool_message_block(_content: String) -> void:
	# 1. 立即使用硬编码的 "tool" 角色设置标题并清空显示
	_set_message_block_title("tool", "")
	_message_block_context_clean()
	# 2. 启动一个独立的异步任务来逐行渲染内容
	_render_content_by_line_async(_content)


# 这是实现打字机效果和实时解析的核心函数。
# 它采用混合模式：默认情况下，它会快速地将文本刷新到UI。
# 但当检测到可能的代码块标记时，它会切换到行缓冲模式进行精确解析。
func append_chunk(_chunk: String) -> void:
	# 如果当前已在代码块内部，或者正在为潜在的代码块标记进行行缓冲，
	# 必须采用标准的行缓冲处理，以确保代码和标记的完整性。
	if current_parse_state == _ParseState.IN_CODE or is_buffering_potential_code_line:
		line_buffer += _chunk
		_process_buffered_lines()
		return
	
	# --- 核心优化：处理普通文本流的“快速路径” ---
	var current_pos: int = 0
	while current_pos < _chunk.length():
		# 如果当前指针位于数据块的开头，且我们知道这是新一行的开始。
		if is_start_of_line:
			# 寻找第一个非空白字符的位置。
			var first_char_pos: int = -1
			for i in range(current_pos, _chunk.length()):
				# 这里直接检查字符是否为空格或制表符。
				if _chunk[i] != ' ' and _chunk[i] != '\t':
					first_char_pos = i
					break
			
			# 如果找到了非空白字符，并且它是 '`' 或 '~'，则切换到行缓冲模式。
			if first_char_pos != -1 and (_chunk[first_char_pos] == '`' or _chunk[first_char_pos] == '~'):
				is_buffering_potential_code_line = true
				# 将本数据块剩余的部分全部放入行缓冲，然后等待更多数据形成完整的一行。
				line_buffer = _chunk.substr(current_pos)
				_process_buffered_lines() # 尝试处理，也许这一块数据本身就包含了换行符。
				return # 退出循环，等待下一次append_chunk调用。
			else:
				# 如果不是潜在的代码块标记，则确认本行是普通文本，关闭新行标记。
				# 只有在 chunk 中确实存在非空白字符时才关闭标记，
				# 否则一个只包含空白的 chunk 可能会错误地将下一块数据视为同一行。
				if first_char_pos != -1:
					is_start_of_line = false
		
		# 在当前数据块中查找下一个换行符。
		var newline_pos: int = _chunk.find("\n", current_pos)
		
		# 如果没找到换行符，说明从 current_pos 到末尾都是同一行的文本。
		if newline_pos == -1:
			var segment: String = _chunk.substr(current_pos)
			_flush_text_to_ui(segment) # 直接将这部分文本刷新到UI。
			current_pos = _chunk.length() # 标记数据块处理完毕。
		# 如果找到了换行符。
		else:
			# 提取从当前位置到换行符（包含换行符本身）的文本片段。
			var segment: String = _chunk.substr(current_pos, newline_pos - current_pos + 1)
			_flush_text_to_ui(segment) # 刷新这部分文本。
			is_start_of_line = true # 标记下一块数据将是新一行的开始。
			current_pos = newline_pos + 1 # 更新指针到换行符之后。


# 当外部数据流结束时调用，用于处理缓冲中可能剩余的最后内容。
func flush_assistant_stream_output() -> void:
	# 如果行缓冲中还有残留数据（例如，文件的最后一行没有换行符），则处理它。
	if not line_buffer.is_empty():
		_process_line(line_buffer)
		line_buffer = ""
	
	# 确保所有UI节点（特别是最后一个）的打字机效果都已完成，显示全部文本。
	_force_finish_last_rtf_animation()


# 这是一个新的公共接口，专门为从存档加载历史记录而设计。
# 它内部调用了逐行异步渲染函数，以实现最流畅的加载体验。
func set_message_from_archive_async(_role: String, _content: String, _model_name: String = "") -> void:
	# 立即设置好标题并清空旧内容
	_set_message_block_title(_role, _model_name)
	_message_block_context_clean()
	
	# 等待逐行渲染协程执行完毕
	await _render_content_by_line_async(_content)
	
	# 确保所有内容都立即显示，而不是等待打字机效果
	# (注意: _render_content_by_line_async 内部的 flush_assistant_stream_output
	# 已经处理了大部分情况，这里是双重保险)
	await get_tree().process_frame
	for child in content_container.get_children():
		if child is RichTextLabel:
			var rtf: RichTextLabel = child
			rtf.visible_characters = rtf.get_total_character_count()


#==============================================================================
# ## 内部函数 ##
#==============================================================================

# 设置消息块的标题，根据角色显示不同的图标和文本。
func _set_message_block_title(_role: String, _model_name: String) -> void:
	match _role:
		"user":
			self.title = "🧑‍💻 You"
		"assistant":
			var assistant_name = "Assistant"
			if not _model_name.is_empty():
				assistant_name += "/" + _model_name
			self.title = "🤖 %s" % assistant_name
		"tool":
			self.title = "⚙️ Tool Output"
		_:
			self.title = "System"


# 异步逐行渲染内容的内部实现。
func _render_content_by_line_async(_full_content: String, _instant_display: bool = false) -> void:
	var lines: PackedStringArray = _full_content.split("\n")
	for i in range(lines.size()):
		var line: String = lines[i]
		
		# 这里我们直接处理每一行，而不是调用 append_chunk，以简化逻辑
		# 因为这是一个完整的、非流式的内容
		if current_parse_state == _ParseState.IN_TEXT:
			var m_open: RegExMatch = re_fence_open.search(line)
			if m_open:
				var text_before_fence: String = line.substr(0, m_open.get_start(0))
				if not text_before_fence.is_empty():
					_flush_text_to_ui(text_before_fence, _instant_display)
				
				current_parse_state = _ParseState.IN_CODE
				var fence_str: String = m_open.get_string(1)
				code_fence_char = fence_str
				code_fence_len = fence_str.length()
				_append_to_code_block("\n")
			else:
				_flush_text_to_ui(line + "\n", _instant_display)
		else: # _ParseState.IN_CODE
			var m_close: RegExMatch = re_fence_close.search(line)
			if m_close and m_close.get_string(1) == code_fence_char and m_close.get_string(1).length() == code_fence_len:
				current_parse_state = _ParseState.IN_TEXT
				code_fence_char = ""
				code_fence_len = 0
			else:
				_append_to_code_block(line + "\n")

		if i % 5 == 0: # 每处理5行，等待一帧，避免单行过长或过多导致卡顿
			await get_tree().process_frame
	
	# 等待最后一帧确保UI更新
	await get_tree().process_frame


# 循环查找换行符，并将每行交给 _process_line 函数处理。
func _process_buffered_lines() -> void:
	var newline_pos: int = line_buffer.find("\n")
	# 只要还能在缓冲区中找到换行符，就持续处理。
	while newline_pos != -1:
		# 提取一行（不包含换行符）。
		var line_to_process: String = line_buffer.substr(0, newline_pos)
		# 从缓冲区中移除已提取的行和它后面的换行符。
		line_buffer = line_buffer.substr(newline_pos + 1)
		
		_process_line(line_to_process)
		
		# 一个关键的逻辑转换点：如果在处理完一行后（例如代码块结束），
		# 解析状态从代码模式切换回了文本模式，并且我们不再处于“潜在代码行”的怀疑状态，
		# 那么缓冲区中剩余的内容就不应该再按行缓冲模式处理了。
		# 它们应该被送回 append_chunk 的“快速路径”进行即时处理。
		if current_parse_state == _ParseState.IN_TEXT and not is_buffering_potential_code_line:
			var remaining_buffer: String = line_buffer
			line_buffer = ""
			append_chunk(remaining_buffer) # 将剩余部分重新注入处理流程。
			return # 退出循环，因为append_chunk会接管后续处理。
		
		# 继续在更新后的缓冲区中查找下一个换行符。
		newline_pos = line_buffer.find("\n")


# 这是状态机逻辑的核心分发器。
func _process_line(_line: String) -> void:
	# 如果我们是从“潜在代码行缓冲”状态过来的，现在有了一整行，就可以重置这个标记了。
	if is_buffering_potential_code_line:
		is_buffering_potential_code_line = false # 重置状态。
		is_start_of_line = true # 下一块数据将被视为新一行的开始。
	
	if current_parse_state == _ParseState.IN_TEXT:
		_parse_line_in_text_state(_line)
	else: # _ParseState.IN_CODE
		_parse_line_in_code_state(_line)


# 主要任务是检测代码块的开始标记。
func _parse_line_in_text_state(_line: String) -> void:
	var m_open: RegExMatch = re_fence_open.search(_line)
	# 如果匹配到了代码块的开始标记...
	if m_open:
		# 将标记之前可能存在的文本先刷新到UI。
		var text_before_fence: String = _line.substr(0, m_open.get_start(0))
		if not text_before_fence.is_empty():
			_flush_text_to_ui(text_before_fence)
		
		# --- 状态转换：进入代码模式 ---
		current_parse_state = _ParseState.IN_CODE
		var fence_str: String = m_open.get_string(1)
		code_fence_char = fence_str # 记录围栏字符和长度，用于精确匹配结束标记。
		code_fence_len = fence_str.length()
		
		# 不提取语言提示，而是用一个换行符代替，以避免代码块开头出现语言标记。
		_append_to_code_block("\n")

	else:
		# 如果不是代码块标记，就当作普通文本行处理，并加上换行符。
		_flush_text_to_ui(_line + "\n")


# 主要任务是检测代码块的结束标记。
func _parse_line_in_code_state(_line: String) -> void:
	var m_close: RegExMatch = re_fence_close.search(_line)
	# 如果匹配到了结束标记，并且其字符和长度与开始标记完全一致...
	if m_close and m_close.get_string(1) == code_fence_char and m_close.get_string(1).length() == code_fence_len:
		# --- 状态转换：回到文本模式 ---
		current_parse_state = _ParseState.IN_TEXT
		code_fence_char = ""
		code_fence_len = 0
	else:
		# 如果不是结束标记，就当作普通的代码行，并加上换行符追加到代码块。
		_append_to_code_block(_line + "\n")


# 从一个完整的字符串内容重绘整个显示区域。
func _redraw_display_from_full_content(_full_content: String) -> void:
	_message_block_context_clean()
	# 为了重用复杂的解析逻辑，我们模拟流式输入的过程。
	append_chunk(_full_content)
	flush_assistant_stream_output()
	# 对于非流式内容，我们希望立即显示所有文本，而不是使用打字机效果。
	# 等待一帧确保所有UI节点都已创建并加入场景树。
	await get_tree().process_frame
	for child in content_container.get_children():
		if child is RichTextLabel:
			var rtf: RichTextLabel = child
			rtf.visible_characters = rtf.get_total_character_count()


# 强制完成上一个RichTextLabel的打字机动画。
# 在创建新的UI节点（如另一个文本块或代码块）之前调用，确保视觉连贯性。
func _force_finish_last_rtf_animation() -> void:
	if is_instance_valid(last_ui_node) and last_ui_node is RichTextLabel:
		var rtf: RichTextLabel = last_ui_node
		# 如果动画未完成，则立即完成它。
		if rtf.visible_characters < rtf.get_total_character_count():
			rtf.visible_characters = rtf.get_total_character_count()


# 将文本内容刷新（添加或追加）到UI上。
# 它会智能地判断是创建一个新的文本块，还是追加到现有的文本块中。
func _flush_text_to_ui(_text: String, _instant_display: bool = false) -> void:
	if _text.is_empty():
		return
	if not last_ui_node is RichTextLabel:
		_add_text_block(_text, _instant_display)
	else:
		last_ui_node.text += _text
		# 如果是即时显示模式，确保追加的文本也立即显示
		if _instant_display:
			last_ui_node.visible_characters = -1


# 将一行代码追加到CodeEdit块中。
# 同样会智能判断是创建新块还是追加内容。
func _append_to_code_block(_code_line: String) -> void:
	# 如果最后一个UI节点不是CodeEdit，说明代码块刚开始，需要创建一个新的。
	if not last_ui_node is CodeEdit:
		_add_code_block(_code_line)
	else:
		# 否则，直接追加代码行。
		last_ui_node.text += _code_line


# 创建并添加一个新的文本块 (RichTextLabel)。
func _add_text_block(_text: String, _instant_display: bool = false) -> void:
	if _text.is_empty(): return
	_force_finish_last_rtf_animation()
	var rich_text: RichTextLabel = RichTextLabel.new()
	rich_text.bbcode_enabled = false
	rich_text.text = _text
	rich_text.fit_content = true
	rich_text.selection_enabled = true
	# 关键修改：根据参数决定是否启用打字机效果
	# -1 表示显示所有字符
	rich_text.visible_characters = -1 if _instant_display else 0
	content_container.add_child(rich_text)
	last_ui_node = rich_text


# 创建并添加一个新的代码块 (CodeEdit)。
func _add_code_block(_code_content: String) -> void:
	if _code_content.is_empty(): return
	# 在创建新节点前，强制完成上一个节点的动画。
	_force_finish_last_rtf_animation()
	var code_edit: CodeEdit = CodeEdit.new()
	code_edit.text = _code_content
	code_edit.editable = false
	code_edit.syntax_highlighter = SYNTAX_HIGHLIGHTER_RES
	code_edit.scroll_fit_content_height = true
	code_edit.draw_tabs = true
	code_edit.scroll_past_end_of_file = true
	code_edit.gutters_draw_line_numbers = true
	var save_button: Button = Button.new()
	save_button.text = "Copy Code"
	content_container.add_child(code_edit)
	content_container.add_child(save_button)
	save_button.pressed.connect(_on_save_button_pressed.bind(save_button))
	last_ui_node = code_edit # 更新最后一个节点的引用。


func _on_save_button_pressed(_save_button: Button) -> void:
	var vbc: VBoxContainer = self.find_child("VBoxContainer")
	var save_button_index: int = _save_button.get_index()
	var code_eidt: CodeEdit = vbc.get_child(save_button_index - 1)
	DisplayServer.clipboard_set(code_eidt.text)


# 清空所有显示内容和内部状态，为新消息做准备。
func _message_block_context_clean() -> void:
	# 释放所有子节点。
	if is_instance_valid(content_container):
		for child in content_container.get_children():
			child.queue_free()
	
	# 重置所有状态变量到初始值。
	last_ui_node = null
	line_buffer = ""
	current_parse_state = _ParseState.IN_TEXT
	code_fence_char = ""
	code_fence_len = 0
	is_start_of_line = true
	is_buffering_potential_code_line = false
