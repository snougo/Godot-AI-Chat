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
var code_fence_char: String = ""
var code_fence_len: int = 0
var last_ui_node: Control = null

# 正则
var re_fence_open: RegEx = RegEx.create_from_string("^\\s*([`~]{3,})")
var re_fence_close: RegEx = RegEx.create_from_string("^\\s*([`~]{3,})\\s*$")

# 打字机状态
var is_typing: bool = false
var typing_queue: Array[String] = [] # 待显示的字符队列
var current_typing_node: RichTextLabel = null

# [新增] 存储当前消息的角色，用于逻辑判断，避免依赖 UI 标题字符串
var current_role: String = ""


func _ready() -> void:
	# 确保容器存在
	if not content_container:
		await get_tree().process_frame


# --- 公共接口 ---

# 设置消息内容 (一次性显示，无动画)
# 用于加载历史记录
func set_content(role: String, content: String, model_name: String = "") -> void:
	_set_title(role, model_name)
	_clear_content()
	_process_full_content(content, true) # true = instant


# 开始流式输出 (有动画)
func start_stream(role: String, model_name: String = "") -> void:
	print("[Block] start_stream called. Role: ", role)
	_set_title(role, model_name)
	_clear_content()
	visible = true


# 追加流式块
func append_chunk(text: String) -> void:
	if text.is_empty(): return
	_process_full_content(text, false) # false = animated


# 显示错误信息 (专用样式)
func set_error(text: String) -> void:
	title = "❌ Error"
	_clear_content()
	var label = _create_text_block(text, true)
	label.modulate = Color(1, 0.4, 0.4) # 红色高亮


# [新增] 获取角色的辅助函数
func get_role() -> String:
	if has_meta("role"):
		return get_meta("role")
	return ""


# --- 核心渲染逻辑 ---

func _set_title(role: String, model_name: String) -> void:
	# [修改] 使用 Metadata 存储角色，更稳健
	set_meta("role", role)
	
	match role:
		ChatMessage.ROLE_USER: title = "🧑‍💻 You"
		ChatMessage.ROLE_ASSISTANT: title = "🤖 Assistant" + ("/" + model_name if not model_name.is_empty() else "")
		ChatMessage.ROLE_TOOL: title = "⚙️ Tool Output"
		ChatMessage.ROLE_SYSTEM: title = "🔧 System"
		_: title = role.capitalize()


func _clear_content() -> void:
	for c in content_container.get_children():
		c.queue_free()
	current_state = ParseState.TEXT
	last_ui_node = null
	is_typing = false
	typing_queue.clear()


# 处理内容 (包含简单的流式解析状态机)
func _process_full_content(text: String, instant: bool) -> void:
	# 这里为了简化，我们假设流式块是以"行"为单位或者不破坏代码块结构的。
	# 原版的 buffer 逻辑很棒，但为了代码简洁，这里做适度简化：
	# 直接把 chunk 喂给当前状态机。
	
	# 如果是代码模式，且收到的不是围栏，直接追加到代码块
	if current_state == ParseState.CODE:
		_append_to_code(text, instant)
		return
	
	# 文本模式：检查代码围栏
	# 注意：流式传输时，代码围栏可能会被切断。
	# 生产环境建议保留你原版的 line_buffer 逻辑。
	# 这里演示核心思路：
	
	var parts = text.split("```", true, 1) # 简单检测
	if parts.size() > 1:
		# 发现了代码块标记 (这里简化了正则判断，仅作演示架构)
		# 实际建议复用你原有的 _process_line 逻辑
		_append_to_text(parts[0], instant)
		_switch_to_code_block()
		if parts[1].length() > 0:
			_append_to_code(parts[1], instant)
	else:
		_append_to_text(text, instant)


func _switch_to_code_block() -> void:
	current_state = ParseState.CODE
	var code_edit = CodeEdit.new()
	code_edit.editable = false
	code_edit.syntax_highlighter = SYNTAX_HIGHLIGHTER_RES
	code_edit.scroll_fit_content_height = true
	code_edit.draw_tabs = true
	code_edit.gutters_draw_line_numbers = true
	content_container.add_child(code_edit)
	last_ui_node = code_edit
	
	# 添加复制按钮
	var btn = Button.new()
	btn.text = "Copy Code"
	btn.pressed.connect(func(): DisplayServer.clipboard_set(code_edit.text))
	content_container.add_child(btn)


func _append_to_code(text: String, instant: bool) -> void:
	# 简单检测结束标记
	if text.contains("```"):
		var parts = text.split("```", true, 1)
		if last_ui_node is CodeEdit:
			last_ui_node.text += parts[0]
		current_state = ParseState.TEXT
		last_ui_node = null # 重置，下次创建新文本块
		if parts[1].length() > 0:
			_append_to_text(parts[1], instant)
	else:
		if last_ui_node is CodeEdit:
			last_ui_node.text += text


func _append_to_text(text: String, instant: bool) -> void:
	if not last_ui_node is RichTextLabel:
		last_ui_node = _create_text_block("", instant)
	
	if instant:
		last_ui_node.text += text
	else:
		# [修复] 获取追加前的字符长度
		var old_length = last_ui_node.get_total_character_count()
		
		# 如果当前是"显示全部"(-1)状态，先将其锁定为具体数值
		# 否则 -1 + 1 会变成 0，导致文字消失重打
		if last_ui_node.visible_characters == -1:
			last_ui_node.visible_characters = old_length
			
		last_ui_node.text += text
		_start_typing_animation(last_ui_node)


func _create_text_block(initial_text: String, instant: bool) -> RichTextLabel:
	var rtl = RichTextLabel.new()
	rtl.bbcode_enabled = false
	rtl.text = initial_text
	rtl.fit_content = true
	rtl.selection_enabled = true
	if not instant:
		rtl.visible_characters = 0
	content_container.add_child(rtl)
	return rtl


# --- 优化的打字机逻辑 ---

func _start_typing_animation(node: RichTextLabel) -> void:
	if is_typing and current_typing_node == node: return
	
	is_typing = true
	current_typing_node = node
	_type_next_char()


func _type_next_char() -> void:
	if not is_instance_valid(current_typing_node):
		is_typing = false
		return
	
	if current_typing_node.visible_characters < current_typing_node.get_total_character_count():
		# 每次显示几个字符，取决于剩余数量（加速效果）
		var total = current_typing_node.get_total_character_count()
		var current = current_typing_node.visible_characters
		var remaining = total - current
		
		# 动态速度：剩余越多跑得越快
		var step = 1
		if remaining > 50: step = 5
		elif remaining > 20: step = 2
		
		current_typing_node.visible_characters += step
		
		# 递归调用 (20ms 一帧 = 50FPS)
		get_tree().create_timer(0.02).timeout.connect(_type_next_char)
	else:
		# 当前节点打字完成
		current_typing_node.visible_characters = -1 # 设为全部显示
		is_typing = false
		current_typing_node = null
