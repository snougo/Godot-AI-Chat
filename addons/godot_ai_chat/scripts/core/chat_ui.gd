@tool
extends Control
class_name ChatUI


# 当用户点击发送按钮时发出
signal send_button_pressed(user_prompt: String)
# 当用户点击停止(原Send按钮)按钮时发出
signal stop_button_pressed
# 当用户点击新聊天按钮时发出
signal new_chat_button_pressed
# 当用户在设置页面点击保存按钮时发出
signal settings_save_button_pressed
# 当用户点击重新连接按钮时发出
signal reconnect_button_pressed
# 当用户在下拉菜单中选择了不同的AI模型时发出
signal model_selection_changed(model_name: String)
# 当用户选择文件路径以保存为 .tres 格式后发出
signal save_chat_button_pressed(file_path: String)
# 当用户选择文件路径以保存为 .md 格式后发出
signal save_as_markdown_button_pressed(file_path: String)
# 当用户选择一个聊天存档并点击加载按钮时发出
signal load_chat_button_pressed(archive_name: String)
# 新增：当用户点击总结按钮时发出
signal summarize_button_pressed

# 定义聊天UI的状态
enum UIState {
	IDLE, 
	LOADING, 
	CONNECTING, 
	WAITING_RESPONSE,
	RESPONSE_GENERATING,
	TOOLCALLING, 
	SUMMARIZING, 
	ERROR
}

# 定义文件保存对话框的模式
enum ChatMessagesSaveMode {TRES, MARKDOWN}

# --- 场景节点引用 ---
@onready var status_label: Label = $TabContainer/Chat/VBoxContainer/StatusLabel
@onready var current_token_cost: Label = $TabContainer/Chat/VBoxContainer/CurrentTokenCost
@onready var user_input: TextEdit = $TabContainer/Chat/VBoxContainer/UserInput
@onready var new_chat_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer/NewChatButton
@onready var reconnect_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer2/ReconnectButton
@onready var send_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer3/SendButton
@onready var save_chat_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer/SaveChatButton
@onready var save_as_markdown_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer3/SaveAsMarkdownButton
@onready var load_chat_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer/LoadChatButton
@onready var summarize_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer/SummarizeButton
@onready var model_selector: OptionButton = $TabContainer/Chat/VBoxContainer/HBoxContainer2/ModelSelector
@onready var model_name_filter_input: LineEdit = $TabContainer/Chat/VBoxContainer/HBoxContainer2/ModelNameFilterInput
@onready var chat_archive_selector: OptionButton = $TabContainer/Chat/VBoxContainer/HBoxContainer/ChatArchiveSelector
@onready var settings_panel: Control = $TabContainer/Settings/SettingsPanel
@onready var error_dialog: AcceptDialog = $AcceptDialog
@onready var file_dialog: FileDialog = $FileDialog

var previous_state: UIState = UIState.IDLE
var current_state: UIState
var current_save_mode: ChatMessagesSaveMode
var model_list: Array[String] = []
var init_count: int = 0


func _ready() -> void:
	# 连接UI控件的信号到对应的处理函数
	send_button.pressed.connect(_on_send_button_pressed)
	new_chat_button.pressed.connect(_on_new_chat_button_pressed)
	summarize_button.pressed.connect(_on_summarize_button_pressed)
	model_selector.item_selected.connect(_on_model_selected)
	model_name_filter_input.text_changed.connect(_on_model_name_filter_text_changed)
	settings_panel.settings_saved.connect(_on_settings_save_button_pressed)
	file_dialog.file_selected.connect(_on_file_selected)
	save_chat_button.pressed.connect(_on_save_chat_button_pressed)
	save_as_markdown_button.pressed.connect(_on_save_as_markdown_button_pressed)
	load_chat_button.pressed.connect(_on_load_chat_button_pressed)
	reconnect_button.pressed.connect(_on_reconnect_button_pressed)
	init_count = 1
	# 初始化时更新一次聊天存档列表
	_update_chat_archive_selector()


#==============================================================================
# ## 公共函数 ##
#==============================================================================

# 初始化编辑器依赖，由 plugin.gd 在启动时调用
func initialize_editor_dependencies(_editor_filesystem: EditorFileSystem) -> void:
	# 连接文件系统变化信号，以便在用户创建或删除存档文件时自动刷新列表
	_editor_filesystem.filesystem_changed.connect(_on_filesystem_changed)


# 外部逻辑调用此函数来更新UI的整体状态
func update_ui_state(_new_state: UIState, _payload: String = "") -> void:
	if _new_state == current_state and _new_state != UIState.ERROR: return
	
	previous_state = current_state
	current_state = _new_state
	
	match current_state:
		UIState.IDLE:
			_state_idle(_payload)
		UIState.LOADING:
			_state_loading(_payload)
		UIState.CONNECTING:
			_state_connecting(_payload)
		UIState.WAITING_RESPONSE:
			_state_waiting_response(_payload)
		UIState.RESPONSE_GENERATING:
			_state_response_generating(_payload)
		UIState.TOOLCALLING:
			_state_tool_calling(_payload)
		UIState.SUMMARIZING:
			_state_summarizing(_payload)
		UIState.ERROR:
			_state_error(_payload)


# 当助手消息流式追加完成时调用
func on_assistant_message_appending_complete() -> void:
	if current_state in [UIState.WAITING_RESPONSE, UIState.RESPONSE_GENERATING, UIState.TOOLCALLING]:
		update_ui_state(UIState.IDLE)


# 更新模型下拉列表的内容
func update_model_list(_model_names: Array[String]) -> void:
	update_ui_state(UIState.IDLE, "Ready")
	model_list = _model_names
	_apply_model_filter()


# 当尝试获取从API服务器上获取模型列表请求失败时调用
func on_get_model_list_request_failed(_error_message: String) -> void:
	update_ui_state(UIState.ERROR, _error_message)


# 当检查API连线请求失败时调用
func on_connection_check_request_failed(_error_message: String) -> void:
	update_ui_state(UIState.ERROR, _error_message)


# 当聊天请求失败时调用
func on_chat_request_failed(_error_message: String) -> void:
	update_ui_state(UIState.ERROR, _error_message)


func clear_user_input(_user_prompt: String) -> void:
	user_input.clear()


# 更新UI界面的token数据
func update_token_cost_display(prompt_tokens: int, completion_tokens: int, total_tokens: int) -> void:
	print("[DEBUG 4] ChatUI: Updating label with totals - P:", prompt_tokens, " C:", completion_tokens, " T:", total_tokens)
	current_token_cost.text = "Token Cost: Total: %d (Prompt: %d, Completion: %d)" % [total_tokens, prompt_tokens, completion_tokens]


# 显示一个简单的确认/成功对话框
func show_confirmation(_message: String) -> void:
	error_dialog.title = "Success"
	error_dialog.dialog_text = _message
	error_dialog.popup_centered()


#==============================================================================
# ## 内部状态函数 ##
#==============================================================================

func _state_idle(_payload: String) -> void:
	init_count += 1
	status_label.text = _payload if not _payload.is_empty() else "Ready"
	status_label.modulate = Color.WHITE
	send_button.text = "Send"
	send_button.disabled = false
	user_input.editable = true
	user_input.caret_blink = true
	user_input.caret_type = TextEdit.CARET_TYPE_LINE
	new_chat_button.disabled = false
	summarize_button.disabled = false
	reconnect_button.disabled = false


func _state_loading(_payload: String) -> void:
	status_label.text = _payload if not _payload.is_empty() else "Loading..."
	status_label.modulate = Color.WHITE
	send_button.text = "Send"
	send_button.disabled = true
	user_input.editable = false
	user_input.caret_blink = false
	user_input.caret_type = TextEdit.CARET_TYPE_LINE
	new_chat_button.disabled = true
	summarize_button.disabled = true
	reconnect_button.disabled = true


func _state_connecting(_payload: String) -> void:
	status_label.text = _payload if not _payload.is_empty() else "Connecting"
	status_label.modulate = Color.WHITE
	send_button.text = "Send"
	send_button.disabled = true
	user_input.editable = false
	user_input.caret_blink = false
	new_chat_button.disabled = true
	summarize_button.disabled = true
	reconnect_button.disabled = true


func _state_waiting_response(_payload: String) -> void:
	status_label.text = _payload if not _payload.is_empty() else "AI is processing context..."
	status_label.modulate = Color.AQUAMARINE
	send_button.text = "Stop"
	send_button.disabled = false
	user_input.editable = false
	user_input.caret_blink = false
	new_chat_button.disabled = true
	summarize_button.disabled = true
	reconnect_button.disabled = true
	reconnect_button.disabled = true


func _state_response_generating(_payload) -> void:
	status_label.text = _payload if not _payload.is_empty() else "AI is generating..."
	status_label.modulate = Color.AQUAMARINE
	send_button.text = "Stop" # 修改发送按钮文本
	send_button.disabled = false
	user_input.editable = false
	user_input.caret_blink = false
	new_chat_button.disabled = true
	summarize_button.disabled = true
	reconnect_button.disabled = true


func _state_tool_calling(_payload: String) -> void:
	status_label.text = _payload if not _payload.is_empty() else "Assistant is using tools..."
	status_label.modulate = Color.GOLD # 使用不同的颜色以示区别
	send_button.text = "Stop" # 同样可以停止整个工作流
	send_button.disabled = false
	user_input.editable = false
	user_input.caret_blink = false
	new_chat_button.disabled = true
	reconnect_button.disabled = true


func _state_summarizing(_payload: String) -> void:
	status_label.text = _payload if not _payload.is_empty() else "Summarizing..."
	status_label.modulate = Color.GOLD
	send_button.disabled = true
	user_input.editable = false
	new_chat_button.disabled = true
	summarize_button.disabled = true
	reconnect_button.disabled = true


func _state_error(_payload: String) -> void:
	status_label.modulate = Color.RED
	send_button.text = "Send" # 恢复按钮文本
	send_button.disabled = false # 允许用户重试
	user_input.editable = true
	user_input.caret_blink = true
	user_input.caret_type = TextEdit.CARET_TYPE_LINE
	new_chat_button.disabled = false
	summarize_button.disabled = false
	reconnect_button.disabled = false
	
	# 防止从项目设置中启用插件时因API错误弹窗导致和项目设置窗口起冲突报错
	if init_count == 1:
		init_count += 1
		status_label.text = _payload
	else:
		status_label.text = "Error: Check Popup Window"
		error_dialog.dialog_text = _payload
		await get_tree().process_frame
		error_dialog.popup_centered()


#==============================================================================
# ## 信号回调函数 ##
#==============================================================================

func _on_send_button_pressed() -> void:
	# 根据当前UI状态决定是发送消息还是停止流
	if current_state in [UIState.WAITING_RESPONSE, UIState.RESPONSE_GENERATING, UIState.TOOLCALLING]:
		emit_signal("stop_button_pressed")
	elif current_state == UIState.IDLE:
		var user_prompt: String = user_input.text.strip_edges()
		if not user_prompt.is_empty():
			emit_signal("send_button_pressed", user_prompt)


func _on_new_chat_button_pressed() -> void:
	emit_signal("new_chat_button_pressed")


func _on_reconnect_button_pressed() -> void:
	update_ui_state(UIState.CONNECTING, "Reconnectiong...")
	emit_signal("reconnect_button_pressed")


func _on_settings_save_button_pressed() -> void:
	emit_signal("settings_save_button_pressed")


func _on_model_selected(_index: int) -> void:
	if model_selector.get_item_count() > _index and _index >= 0:
		var model_name: String = model_selector.get_item_text(_index)
		emit_signal("model_selection_changed", model_name)


func _on_model_name_filter_text_changed(_new_text: String) -> void:
	_apply_model_filter()


func _on_save_chat_button_pressed() -> void:
	current_save_mode = ChatMessagesSaveMode.TRES
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.clear_filters()
	file_dialog.add_filter("*.tres", "Godot Chat History")
	file_dialog.current_dir = "res://addons/godot_ai_chat/chat_archives/"
	file_dialog.current_file = _generate_default_filename(".tres")
	file_dialog.popup_centered()


func _on_save_as_markdown_button_pressed() -> void:
	current_save_mode = ChatMessagesSaveMode.MARKDOWN
	file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dialog.clear_filters()
	file_dialog.add_filter("*.md", "Markdown File")
	file_dialog.current_dir = "res://addons/godot_ai_chat/chat_archives/"
	file_dialog.current_file = _generate_default_filename(".md")
	file_dialog.popup_centered()


func _on_load_chat_button_pressed() -> void:
	var selected_index: int = chat_archive_selector.selected
	if selected_index == -1:
		show_confirmation("Please select a chat archive to load.")
		return
	
	var archive_name = chat_archive_selector.get_item_text(selected_index)
	emit_signal("load_chat_button_pressed", archive_name)


func _on_summarize_button_pressed() -> void:
	emit_signal("summarize_button_pressed")


func _on_file_selected(_path: String) -> void:
	if current_save_mode == ChatMessagesSaveMode.TRES:
		emit_signal("save_chat_button_pressed", _path)
	elif current_save_mode == ChatMessagesSaveMode.MARKDOWN:
		emit_signal("save_as_markdown_button_pressed", _path)


func _on_filesystem_changed() -> void:
	_update_chat_archive_selector()


#==============================================================================
# ## 内部辅助函数 ##
#==============================================================================

# 根据模型名称过滤输入框中的文本，更新模型下拉列表
func _apply_model_filter() -> void:
	var filter_text: String = model_name_filter_input.text.strip_edges().to_lower()
	var previously_selected: String = ""
	
	if model_selector.selected != -1:
		previously_selected = model_selector.get_item_text(model_selector.selected)
	
	var filtered_models: Array[String] = []
	for model_name in model_list:
		if filter_text.is_empty() or model_name.to_lower().contains(filter_text):
			filtered_models.append(model_name)
	
	model_selector.clear()
	if filtered_models.is_empty():
		model_selector.add_item("No matching models found")
		model_selector.disabled = true
		emit_signal("model_selection_changed", "")
	else:
		model_selector.disabled = false
		for name in filtered_models:
			model_selector.add_item(name)
		
		var new_selection_index = filtered_models.find(previously_selected)
		if new_selection_index != -1:
			model_selector.select(new_selection_index)
			_on_model_selected(new_selection_index) 
		elif not filtered_models.is_empty():
			model_selector.select(0)
			_on_model_selected(0)


# 扫描存档目录并更新存档下拉列表
func _update_chat_archive_selector() -> void:
	var archives: Array = ChatArchive.get_archive_list()
	var previously_selected: String= ""
	
	if chat_archive_selector.selected != -1:
		previously_selected = chat_archive_selector.get_item_text(chat_archive_selector.selected)
	
	chat_archive_selector.clear()
	if archives.is_empty():
		chat_archive_selector.disabled = true
	else:
		chat_archive_selector.disabled = false
		var new_selection_index: int = -1
		for i in range(archives.size()):
			var archive_name = archives[i]
			chat_archive_selector.add_item(archive_name)
			if archive_name == previously_selected:
				new_selection_index = i
		
		if new_selection_index != -1:
			chat_archive_selector.select(new_selection_index)


# 生成一个基于当前时间的默认文件名
func _generate_default_filename(_extension: String) -> String:
	var now: Dictionary = Time.get_datetime_dict_from_system(false) # false = local time
	var timestamp_str: String = "chat_%d-%02d-%02d_%02d-%02d-%02d" % [now.year, now.month, now.day, now.hour, now.minute, now.second]
	return timestamp_str + _extension
