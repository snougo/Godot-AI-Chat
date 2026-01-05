@tool
extends Control
class_name ChatUI

# --- 信号定义 ---
# 当用户点击发送按钮时发出
signal send_button_pressed(user_prompt: String)
# 当用户点击停止按钮时发出 (原发送按钮在生成时的状态)
signal stop_button_pressed
# 当用户点击新聊天按钮时发出
signal new_chat_button_pressed
# 当用户在设置页面点击保存按钮时发出 (转发 SettingsPanel 的信号)
signal settings_save_button_pressed
# 当用户点击重新连接按钮时发出
signal reconnect_button_pressed
# 当用户在下拉菜单中选择了不同的AI模型时发出
signal model_selection_changed(model_name: String)
# 当用户选择文件路径以保存为 .md 格式后发出
signal save_as_markdown_button_pressed(file_path: String)
# 当用户选择一个聊天存档并点击加载按钮时发出
signal load_chat_button_pressed(archive_name: String)

# --- 状态定义 ---
enum UIState {
	IDLE, 
	CONNECTING, 
	WAITING_RESPONSE,
	RESPONSE_GENERATING,
	TOOLCALLING, 
	ERROR
}

# --- 场景节点引用 ---
@onready var status_label: Label = $TabContainer/Chat/VBoxContainer/StatusLabel
@onready var current_token_cost: Label = $TabContainer/Chat/VBoxContainer/CurrentTokenCost
@onready var user_input: TextEdit = $TabContainer/Chat/VBoxContainer/UserInput
@onready var new_chat_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer/NewChatButton
@onready var reconnect_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer2/ReconnectButton
@onready var send_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer3/SendButton
@onready var save_as_markdown_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer3/SaveAsMarkdownButton
@onready var load_chat_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer/LoadChatButton
@onready var model_selector: OptionButton = $TabContainer/Chat/VBoxContainer/HBoxContainer2/ModelSelector
@onready var model_name_filter_input: LineEdit = $TabContainer/Chat/VBoxContainer/HBoxContainer2/ModelNameFilterInput
@onready var chat_archive_selector: OptionButton = $TabContainer/Chat/VBoxContainer/HBoxContainer/ChatArchiveSelector
@onready var settings_panel: Control = $TabContainer/Settings/SettingsPanel
@onready var error_dialog: AcceptDialog = $AcceptDialog
@onready var file_dialog: FileDialog = $FileDialog
@onready var tab_container: TabContainer = $TabContainer 

# --- 内部变量 ---
var current_state: UIState = UIState.IDLE
var model_list: Array[String] = []
# 用于判断是否为首次运行或初始化阶段
var is_first_init: bool = true


func _ready() -> void:
	# 连接UI控件的信号到对应的处理函数
	send_button.pressed.connect(self._on_send_button_pressed)
	new_chat_button.pressed.connect(self._on_new_chat_button_pressed)
	model_selector.item_selected.connect(self._on_model_selected)
	model_name_filter_input.text_changed.connect(self._on_model_name_filter_text_changed)
	settings_panel.settings_saved.connect(self._on_settings_save_button_pressed)
	file_dialog.file_selected.connect(self._on_file_selected)
	save_as_markdown_button.pressed.connect(self._on_save_as_markdown_button_pressed)
	load_chat_button.pressed.connect(self._on_load_chat_button_pressed)
	reconnect_button.pressed.connect(self._on_reconnect_button_pressed)
	
	# 初始化时更新一次聊天存档列表
	self._update_chat_archive_selector()
	
	# 初始化 Token 显示为 0
	reset_token_cost_display()
	
	# 初始状态
	update_ui_state(UIState.IDLE)


# --- 公共函数 ---

# 初始化编辑器依赖，由 plugin.gd 在启动时调用
func initialize_editor_dependencies(_editor_filesystem: EditorFileSystem) -> void:
	# 连接文件系统变化信号，以便在用户创建或删除存档文件时自动刷新列表
	if not _editor_filesystem.filesystem_changed.is_connected(_on_filesystem_changed):
		_editor_filesystem.filesystem_changed.connect(_on_filesystem_changed)


# 外部逻辑调用此函数来更新UI的整体状态
func update_ui_state(_new_state: UIState, _payload: String = "") -> void:
	current_state = _new_state
	status_label.text = _payload if not _payload.is_empty() else _get_default_status_text(_new_state)
	
	match current_state:
		UIState.IDLE:
			#status_label.text = "Ready"
			#status_label.modulate = Color.WHITE
			# [新增] 逻辑：如果提示信息包含 "No Chat"，使用金色/黄色提醒用户
			if "No Chat" in status_label.text:
				status_label.modulate = Color.GOLD
			else:
				status_label.modulate = Color.WHITE
			send_button.text = "Send"
			send_button.disabled = false
			user_input.editable = true
			user_input.caret_blink = true
			new_chat_button.disabled = false
			reconnect_button.disabled = false
		
		UIState.CONNECTING:
			status_label.text = "Connecting..."
			status_label.modulate = Color.WHITE
			send_button.disabled = true
			user_input.editable = false
			new_chat_button.disabled = true
			reconnect_button.disabled = true
		
		UIState.WAITING_RESPONSE:
			status_label.text = "Waiting for AI response"
			status_label.modulate = Color.AQUAMARINE
			send_button.text = "Stop"
			send_button.disabled = false
			user_input.editable = false
			user_input.caret_blink = false
			new_chat_button.disabled = true
			reconnect_button.disabled = true
		
		UIState.RESPONSE_GENERATING:
			status_label.text = "AI is generating..."
			status_label.modulate = Color.AQUAMARINE
			send_button.text = "Stop"
			send_button.disabled = false
			user_input.editable = false
			new_chat_button.disabled = true
			reconnect_button.disabled = true
		
		UIState.TOOLCALLING:
			status_label.text = "⚙️ Executing Tools... " + _payload
			status_label.modulate = Color.GOLD
			send_button.text = "Stop"
			send_button.disabled = false
			user_input.editable = false
			new_chat_button.disabled = true
			reconnect_button.disabled = true
		
		UIState.ERROR:
			status_label.text = "Checking The Popup Window for Error Message"
			status_label.modulate = Color.RED
			send_button.text = "Send"
			send_button.disabled = false # 允许重试
			user_input.editable = true
			new_chat_button.disabled = false
			reconnect_button.disabled = false
			
			if not _payload.is_empty():
				_show_error_dialog(_payload)


# 更新模型下拉列表的内容
func update_model_list(_model_names: Array[String]) -> void:
	# 检查当前状态栏是否包含特殊的初始化提示
	# 如果包含，则不使用 "Ready" 覆盖它
	var current_msg := status_label.text
	if not ("No Chat" in current_msg):
		update_ui_state(UIState.IDLE, "Ready")
	
	model_list = _model_names
	_apply_model_filter()



# 当尝试获取从API服务器上获取模型列表请求失败时调用
func get_model_list_request_failed(_error_message: String) -> void:
	if not is_first_init:
		update_ui_state(UIState.ERROR, _error_message)
	else:
		# 保证如果启用插件后获取模型列表失败
		# 不会导致错误提示信息的弹窗和项目设置窗口产生冲突从而引发报错
		# 因此我们在这手动设置一次，而不是使用 update_ui_state
		status_label.text = _error_message
		status_label.modulate = Color.RED
		is_first_init = false


# 用于根据文件名同步下拉选择框
func select_archive_by_name(_archive_name: String) -> void:
	# 强制刷新一次列表，确保新创建的文件已在列表中
	_update_chat_archive_selector()
	
	for i in range(chat_archive_selector.get_item_count()):
		if chat_archive_selector.get_item_text(i) == _archive_name:
			chat_archive_selector.select(i)
			return


# 清空用户输入框
func clear_user_input() -> void:
	user_input.clear()


# 更新UI界面的token数据
func update_token_cost_display(usage: Dictionary) -> void:
	# usage 格式: {prompt_tokens, completion_tokens, total_tokens}
	# 如果没有 total_tokens，手动计算
	var p = usage.get("prompt_tokens", 0)
	var c = usage.get("completion_tokens", 0)
	var t = usage.get("total_tokens", p + c)
	current_token_cost.text = "Token Cost: Total: %d (Prompt: %d, Completion: %d)" % [t, p, c]


# [新增] 重置 Token 显示（清空或设为 0）
func reset_token_cost_display() -> void:
	current_token_cost.text = "Token Cost: Total: 0 (Prompt: 0, Completion: 0)"


# 显示一个简单的确认/成功对话框
func show_confirmation(_message: String) -> void:
	error_dialog.title = "Notification"
	error_dialog.dialog_text = _message
	error_dialog.popup_centered()


# --- 内部辅助函数 ---

func _get_default_status_text(state: UIState) -> String:
	match state:
		UIState.IDLE: return "Ready"
		UIState.CONNECTING: return "Connecting..."
		UIState.WAITING_RESPONSE: return "Waiting for AI..."
		UIState.RESPONSE_GENERATING: return "Generating..."
		UIState.TOOLCALLING: return "Using Tools..."
		UIState.ERROR: return "Error"
	return ""


func _show_error_dialog(msg: String) -> void:
	error_dialog.title = "Error"
	error_dialog.dialog_text = msg
	error_dialog.popup_centered()


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
			var archive_name: String = archives[i]
			chat_archive_selector.add_item(archive_name)
			
			if archive_name == previously_selected:
				new_selection_index = i
		
		if new_selection_index != -1:
			chat_archive_selector.select(new_selection_index)


func _generate_default_filename(extension: String) -> String:
	var now: Dictionary = Time.get_datetime_dict_from_system(false)
	var timestamp_str: String = "chat_%d-%02d-%02d_%02d-%02d-%02d" % [now.year, now.month, now.day, now.hour, now.minute, now.second]
	return timestamp_str + extension


# --- 信号回调函数 ---

func _on_send_button_pressed() -> void:
	# 根据当前状态，Send 按钮可能扮演 Stop 按钮的角色
	if current_state in [UIState.WAITING_RESPONSE, UIState.RESPONSE_GENERATING, UIState.TOOLCALLING]:
		emit_signal("stop_button_pressed")
	elif current_state == UIState.IDLE or current_state == UIState.ERROR:
		var user_prompt: String = user_input.text.strip_edges()
		if not user_prompt.is_empty():
			emit_signal("send_button_pressed", user_prompt)


func _on_new_chat_button_pressed() -> void:
	emit_signal("new_chat_button_pressed")


func _on_reconnect_button_pressed() -> void:
	emit_signal("reconnect_button_pressed")


func _on_settings_save_button_pressed() -> void:
	# 转发信号给 ChatHub (用于触发 NetworkManager 刷新配置)
	emit_signal("settings_save_button_pressed")
	
	# 自动切换回聊天标签页 (Tab 0)
	if tab_container:
		tab_container.current_tab = 0


func _on_model_selected(index: int) -> void:
	if model_selector.get_item_count() > index and index >= 0:
		var model_name: String = model_selector.get_item_text(index)
		emit_signal("model_selection_changed", model_name)


func _on_model_name_filter_text_changed(_new_text: String) -> void:
	_apply_model_filter()


func _on_save_as_markdown_button_pressed() -> void:
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


func _on_file_selected(path: String) -> void:
	# FileDialog 目前只用于 Markdown 导出
	emit_signal("save_as_markdown_button_pressed", path)


func _on_filesystem_changed() -> void:
	_update_chat_archive_selector()
