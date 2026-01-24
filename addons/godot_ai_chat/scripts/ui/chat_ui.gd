@tool
class_name ChatUI
extends Control

## 负责管理插件的主要 UI 交互，包括状态切换、模型选择、存档管理等。

# --- Signals ---

## 当用户点击发送按钮时发出
signal send_button_pressed(user_prompt: String)
## 当用户点击停止按钮时发出
signal stop_button_pressed
## 当用户点击新聊天按钮时发出
signal new_chat_button_pressed
## 当用户在设置页面点击保存按钮时发出
signal settings_save_button_pressed
## 当用户点击重新连接按钮时发出
signal reconnect_button_pressed
## 当用户在下拉菜单中选择了不同的 AI 模型时发出
signal model_selection_changed(model_name: String)
## 当用户选择文件路径以保存为 .md 格式后发出
signal save_as_markdown_button_pressed(file_path: String)
## 当用户选择一个聊天存档并点击加载按钮时发出
signal load_chat_button_pressed(archive_name: String)
## 当用户点击删除按钮时发出
signal delete_chat_button_pressed(archive_name: String)

# --- Enums ---

## UI 状态定义
enum UIState {
	IDLE,                ## 空闲状态
	CONNECTING,          ## 正在连接服务器
	WAITING_RESPONSE,    ## 等待 AI 响应
	RESPONSE_GENERATING, ## 正在生成响应
	TOOLCALLING,         ## 正在执行工具调用
	ERROR                ## 发生错误
}

# --- @onready Vars ---

@onready var _status_label: Label = $TabContainer/Chat/VBoxContainer/StatusLabel
@onready var _chat_turn_display: Label = $TabContainer/Chat/VBoxContainer/ChatTrunDisplay
@onready var _current_token_cost: Label = $TabContainer/Chat/VBoxContainer/CurrentTokenCost

@onready var _chat_archive_selector: OptionButton = $TabContainer/Chat/VBoxContainer/ChatArchiveContainer/ChatArchiveSelector
@onready var _delete_chat_button: Button = $TabContainer/Chat/VBoxContainer/ChatArchiveContainer/DeleteButton
@onready var _load_chat_button: Button = $TabContainer/Chat/VBoxContainer/ChatArchiveContainer/LoadChatButton
@onready var _new_chat_button: Button = $TabContainer/Chat/VBoxContainer/ChatArchiveContainer/NewChatButton

@onready var _send_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer/SendButton
@onready var _save_as_markdown_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer/SaveAsMarkdownButton
@onready var _user_input: TextEdit = $TabContainer/Chat/VBoxContainer/UserInput

@onready var _model_selector: OptionButton = $TabContainer/Chat/VBoxContainer/NetworkContainer/ModelSelector
@onready var _model_name_filter_input: LineEdit = $TabContainer/Chat/VBoxContainer/NetworkContainer/ModelNameFilterInput
@onready var _reconnect_button: Button = $TabContainer/Chat/VBoxContainer/NetworkContainer/ReconnectButton

@onready var _settings_panel: Control = $TabContainer/Settings/SettingsPanel
@onready var _error_dialog: AcceptDialog = $AcceptDialog
@onready var _file_dialog: FileDialog = $FileDialog
@onready var _tab_container: TabContainer = $TabContainer 

# [Refactor] 新增：暴露给 Controller 使用的内部节点引用
@onready var _chat_list_container: VBoxContainer = $TabContainer/Chat/VBoxContainer/ChatDisplayView/ScrollContainer/ChatListContainer
@onready var _chat_scroll_container: ScrollContainer = $TabContainer/Chat/VBoxContainer/ChatDisplayView/ScrollContainer
@onready var _settings_panel_node: SettingsPanel = $TabContainer/Settings/SettingsPanel

# --- Public Vars ---

## 当前 UI 状态
var current_state: UIState = UIState.IDLE
## 缓存的模型列表
var model_list: Array[String] = []
## 用于判断是否为首次运行或初始化阶段
var is_first_init: bool = false

## 标记当前是否在等待删除确认
var _pending_delete_archive_name: String = ""


# --- Built-in Functions ---

func _ready() -> void:
	_settings_panel.settings_saved.connect(_on_settings_save_button_pressed)
	_file_dialog.file_selected.connect(_on_file_selected)
	
	_delete_chat_button.pressed.connect(_on_delete_chat_button_pressed)
	_load_chat_button.pressed.connect(_on_load_chat_button_pressed)
	_new_chat_button.pressed.connect(_on_new_chat_button_pressed)
	
	_model_selector.item_selected.connect(_on_model_selected)
	_model_name_filter_input.text_changed.connect(_on_model_name_filter_text_changed)
	_reconnect_button.pressed.connect(_on_reconnect_button_pressed)
	
	_save_as_markdown_button.pressed.connect(_on_save_as_markdown_button_pressed)
	_send_button.pressed.connect(_on_send_button_pressed)
	
	_update_chat_archive_selector()
	reset_token_cost_display()
	update_ui_state(UIState.IDLE)


# --- Public Functions ---

# [Refactor] 新增：公共访问方法
func get_chat_list_container() -> VBoxContainer:
	return _chat_list_container


func get_chat_scroll_container() -> ScrollContainer:
	return _chat_scroll_container


func get_settings_panel() -> SettingsPanel:
	return _settings_panel_node


## 初始化编辑器依赖
func initialize_editor_dependencies(_editor_filesystem: EditorFileSystem) -> void:
	if not _editor_filesystem.filesystem_changed.is_connected(_on_filesystem_changed):
		_editor_filesystem.filesystem_changed.connect(_on_filesystem_changed)


## 更新 UI 的整体状态
func update_ui_state(_new_state: UIState, _payload: String = "") -> void:
	current_state = _new_state
	_status_label.text = _payload if not _payload.is_empty() else _get_default_status_text(_new_state)
	
	match current_state:
		UIState.IDLE:
			if "No Chat" in _status_label.text:
				_status_label.modulate = Color.GOLD
			else:
				_status_label.modulate = Color.WHITE
			_user_input.editable = true
			_user_input.caret_blink = true
			_send_button.text = "Send"
			_send_button.disabled = false
			_delete_chat_button.disabled = false
			_load_chat_button.disabled = false
			_save_as_markdown_button.disabled = false
			_new_chat_button.disabled = false
			_reconnect_button.disabled = false
		
		UIState.CONNECTING:
			#_status_label.text = "Connecting..."
			_status_label.modulate = Color.WHITE
			_user_input.editable = false
			_user_input.caret_blink = false
			_send_button.text = "Send"
			_send_button.disabled = true
			_delete_chat_button.disabled = true
			_load_chat_button.disabled = true
			_save_as_markdown_button.disabled = true
			_new_chat_button.disabled = true
			_reconnect_button.disabled = true
		
		UIState.WAITING_RESPONSE:
			#_status_label.text = "Waiting for AI response"
			_status_label.modulate = Color.AQUAMARINE
			_user_input.editable = false
			_user_input.caret_blink = false
			_send_button.text = "Stop"
			_send_button.disabled = false
			_delete_chat_button.disabled = true
			_load_chat_button.disabled = true
			_save_as_markdown_button.disabled = true
			_new_chat_button.disabled = true
			_reconnect_button.disabled = true
		
		UIState.RESPONSE_GENERATING:
			#_status_label.text = "AI is generating..."
			_status_label.modulate = Color.AQUAMARINE
			_user_input.editable = false
			_user_input.caret_blink = false
			_send_button.text = "Stop"
			_send_button.disabled = false
			_delete_chat_button.disabled = true
			_load_chat_button.disabled = true
			_save_as_markdown_button.disabled = true
			_new_chat_button.disabled = true
			_reconnect_button.disabled = true
		
		UIState.TOOLCALLING:
			#_status_label.text = "⚙️ Executing Tools... " + _payload
			_status_label.modulate = Color.GOLD
			_user_input.editable = false
			_user_input.caret_blink = false
			_send_button.text = "Stop"
			_send_button.disabled = true
			_delete_chat_button.disabled = true
			_load_chat_button.disabled = true
			_save_as_markdown_button.disabled = true
			_new_chat_button.disabled = true
			_reconnect_button.disabled = true
		
		UIState.ERROR:
			#_status_label.text = "Checking The Popup Window for Error Message"
			_status_label.modulate = Color.RED
			_user_input.editable = false
			_user_input.caret_blink = false
			_send_button.text = "Send"
			_send_button.disabled = true
			_delete_chat_button.disabled = false
			_load_chat_button.disabled = false
			_save_as_markdown_button.disabled = false
			_new_chat_button.disabled = false
			_reconnect_button.disabled = false
			
			if not _payload.is_empty():
				_show_error_dialog(_payload)


## 更新模型下拉列表的内容
func update_model_list(_model_names: Array[String]) -> void:
	var _current_msg: String = _status_label.text
	if not ("No Chat" in _current_msg):
		update_ui_state(UIState.IDLE, "Ready")
	
	model_list = _model_names
	_apply_model_filter()


## 当获取模型列表请求失败时调用
func get_model_list_request_failed(_error_message: String) -> void:
	if is_first_init:
		update_ui_state(UIState.ERROR, _error_message)
	else:
		_status_label.text = _error_message
		_status_label.modulate = Color.RED
		is_first_init = true


## 根据文件名同步下拉选择框
func select_archive_by_name(_archive_name: String) -> void:
	_update_chat_archive_selector()
	
	for _i in range(_chat_archive_selector.get_item_count()):
		if _chat_archive_selector.get_item_text(_i) == _archive_name:
			_chat_archive_selector.select(_i)
			return


## 清空用户输入框
func clear_user_input() -> void:
	_user_input.clear()


## 更新对话轮数显示
func update_turn_display(_current_turns: int, _max_turns: int) -> void:
	if _chat_turn_display:
		_chat_turn_display.text = "Turns: %d / %d" % [_current_turns, _max_turns]
		
		# 当达到或超过最大轮数时，改变颜色示警（例如橙色）
		if _current_turns >= _max_turns:
			_chat_turn_display.modulate = Color(1, 0.6, 0.2)
		else:
			_chat_turn_display.modulate = Color.WHITE


## 更新 UI 界面的 Token 数据
func update_token_cost_display(_usage: Dictionary) -> void:
	var _p: int = _usage.get("prompt_tokens", 0)
	var _c: int = _usage.get("completion_tokens", 0)
	var _t: int = _usage.get("total_tokens", _p + _c)
	_current_token_cost.text = "Token Cost: Total: %d (Prompt: %d, Completion: %d)" % [_t, _p, _c]


## 重置 Token 显示
func reset_token_cost_display() -> void:
	_current_token_cost.text = "Token Cost: Total: 0 (Prompt: 0, Completion: 0)"


## 显示一个确认/成功对话框
func show_confirmation(_message: String) -> void:
	_error_dialog.title = "Notification"
	_error_dialog.dialog_text = _message
	
	# 断开删除确认连接，避免干扰普通通知
	if _error_dialog.confirmed.is_connected(_on_delete_confirmed):
		_error_dialog.confirmed.disconnect(_on_delete_confirmed)
		_pending_delete_archive_name = ""
	
	_error_dialog.popup_centered()


# --- Private Functions ---

func _get_default_status_text(_state: UIState) -> String:
	match _state:
		UIState.IDLE: return "Ready"
		UIState.CONNECTING: return "Connecting..."
		UIState.WAITING_RESPONSE: return "Waiting for LLM response"
		UIState.RESPONSE_GENERATING: return "LLM is generating"
		UIState.TOOLCALLING: return "Executing Tools..."
		UIState.ERROR: return "Error"
	return ""


func _show_error_dialog(_msg: String) -> void:
	_error_dialog.title = "Error"
	_error_dialog.dialog_text = _msg
	_error_dialog.popup_centered()


func _apply_model_filter() -> void:
	var _filter_text: String = _model_name_filter_input.text.strip_edges().to_lower()
	var _previously_selected: String = ""
	
	if _model_selector.selected != -1:
		_previously_selected = _model_selector.get_item_text(_model_selector.selected)
	
	var _filtered_models: Array[String] = []
	for _model_name in model_list:
		if _filter_text.is_empty() or _model_name.to_lower().contains(_filter_text):
			_filtered_models.append(_model_name)
	
	_model_selector.clear()
	if _filtered_models.is_empty():
		_model_selector.add_item("No matching models found")
		_model_selector.disabled = true
		model_selection_changed.emit("")
	else:
		_model_selector.disabled = false
		for _name in _filtered_models:
			_model_selector.add_item(_name)
		
		var _new_selection_index: int = _filtered_models.find(_previously_selected)
		if _new_selection_index != -1:
			_model_selector.select(_new_selection_index)
			_on_model_selected(_new_selection_index) 
		elif not _filtered_models.is_empty():
			_model_selector.select(0)
			_on_model_selected(0)


func _update_chat_archive_selector() -> void:
	var _archives: Array[String] = ChatArchive.get_archive_list()
	var _previously_selected: String = ""
	
	if _chat_archive_selector.selected != -1:
		_previously_selected = _chat_archive_selector.get_item_text(_chat_archive_selector.selected)
	
	_chat_archive_selector.clear()
	
	if _archives.is_empty():
		_chat_archive_selector.disabled = true
	else:
		_chat_archive_selector.disabled = false
		var _new_selection_index: int = -1
		for _i in range(_archives.size()):
			var _archive_name: String = _archives[_i]
			_chat_archive_selector.add_item(_archive_name)
			
			if _archive_name == _previously_selected:
				_new_selection_index = _i
		
		if _new_selection_index != -1:
			_chat_archive_selector.select(_new_selection_index)


func _generate_default_filename(_extension: String) -> String:
	var _now: Dictionary = Time.get_datetime_dict_from_system(false)
	var _timestamp_str: String = "chat_%d-%02d-%02d_%02d-%02d-%02d" % [_now.year, _now.month, _now.day, _now.hour, _now.minute, _now.second]
	return _timestamp_str + _extension


# --- Signal Callbacks ---

func _on_delete_chat_button_pressed() -> void:
	var _selected_index: int = _chat_archive_selector.selected
	if _selected_index == -1:
		show_confirmation("Please select a chat archive to delete.")
		return
	
	var _archive_name: String = _chat_archive_selector.get_item_text(_selected_index)
	
	# 设置确认对话框
	_error_dialog.title = "Confirm Delete"
	_error_dialog.dialog_text = "Are you sure you want to delete '%s'?\n\nThis action cannot be undone." % _archive_name
	
	# 保存待删除的存档名
	_pending_delete_archive_name = _archive_name
	
	# 连接确认信号（确保只连接一次）
	if not _error_dialog.confirmed.is_connected(_on_delete_confirmed):
		_error_dialog.confirmed.connect(_on_delete_confirmed)
	
	_error_dialog.popup_centered()


## 用户确认删除后的回调
func _on_delete_confirmed() -> void:
	if _pending_delete_archive_name.is_empty():
		return
	
	# 发出删除信号
	delete_chat_button_pressed.emit(_pending_delete_archive_name)
	
	# 清空待删除状态
	_pending_delete_archive_name = ""


func _on_load_chat_button_pressed() -> void:
	var _selected_index: int = _chat_archive_selector.selected
	if _selected_index == -1:
		show_confirmation("Please select a chat archive to load.")
		return
	var _archive_name: String = _chat_archive_selector.get_item_text(_selected_index)
	load_chat_button_pressed.emit(_archive_name)


func _on_new_chat_button_pressed() -> void:
	new_chat_button_pressed.emit()


func _on_reconnect_button_pressed() -> void:
	reconnect_button_pressed.emit()


func _on_model_selected(_index: int) -> void:
	if _model_selector.get_item_count() > _index and _index >= 0:
		var _model_name: String = _model_selector.get_item_text(_index)
		model_selection_changed.emit(_model_name)


func _on_model_name_filter_text_changed(_new_text: String) -> void:
	_apply_model_filter()


func _on_save_as_markdown_button_pressed() -> void:
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.clear_filters()
	_file_dialog.add_filter("*.md", "Markdown File")
	_file_dialog.current_dir = "res://addons/godot_ai_chat/chat_archives/"
	_file_dialog.current_file = _generate_default_filename(".md")
	_file_dialog.popup_centered()


func _on_send_button_pressed() -> void:
	if current_state in [UIState.WAITING_RESPONSE, UIState.RESPONSE_GENERATING, UIState.TOOLCALLING]:
		stop_button_pressed.emit()
	elif current_state == UIState.IDLE or current_state == UIState.ERROR:
		var _user_prompt: String = _user_input.text.strip_edges()
		if not _user_prompt.is_empty():
			send_button_pressed.emit(_user_prompt)


func _on_file_selected(_path: String) -> void:
	save_as_markdown_button_pressed.emit(_path)


func _on_settings_save_button_pressed() -> void:
	settings_save_button_pressed.emit()
	if _tab_container:
		_tab_container.current_tab = 0


func _on_filesystem_changed() -> void:
	_update_chat_archive_selector()
