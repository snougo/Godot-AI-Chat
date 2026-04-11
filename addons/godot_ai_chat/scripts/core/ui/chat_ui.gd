@tool
class_name ChatUI
extends Control

## 主 UI 控制器
##
## 负责管理插件的主要 UI 交互，包括状态切换、模型选择、存档管理等。
## 作为 UI 层与业务逻辑层的桥梁，转发信号并更新界面状态。

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
signal load_chat_button_pressed(session_name: String)
## 当用户点击删除按钮时发出
signal delete_chat_button_pressed(session_name: String)
## 当用户通过 UI 切换工作区时发出
signal workspace_changed(new_path: String)

# --- Enums / Constants ---

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
@onready var _chat_turn_display: Label = $TabContainer/Chat/VBoxContainer/ChatTurnDisplay
@onready var _current_token_usage: Label = $TabContainer/Chat/VBoxContainer/CurrentTokenUsage

@onready var _workspace_label: Label = $TabContainer/Chat/VBoxContainer/WorkspaceLabel
@onready var _workspace_select_button: Button = $TabContainer/Chat/VBoxContainer/HBoxContainer/WorkspaceSelectButton
@onready var _workspace_file_dialog: FileDialog = $WorkspaceFileDialog

@onready var _session_selector: OptionButton = $TabContainer/Chat/VBoxContainer/ChatArchiveContainer/SessionSelector
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

# 暴露给 Controller 使用的内部节点引用
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

# --- Private Vars ---

# 标记当前是否在等待删除确认
var _pending_delete_session_name: String = ""
# [Feature] Token Usage Tracking
var _archived_total_usage: Dictionary = { "prompt": 0, "completion": 0, "total": 0 }
var _current_turn_usage: Dictionary = { "prompt": 0, "completion": 0, "total": 0 }


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
	
	_workspace_select_button.pressed.connect(_on_workspace_select_button_pressed)
	_workspace_file_dialog.dir_selected.connect(_on_workspace_dir_selected)
	
	_update_session_selector()
	reset_token_usage_display()
	update_ui_state(UIState.IDLE)
	
	# 初始化工作区显示
	var settings := ToolBox.get_plugin_settings()
	_update_workspace_display(settings.workspace_path)


# --- Public Functions ---

func get_chat_list_container() -> VBoxContainer:
	return _chat_list_container


func get_chat_scroll_container() -> ScrollContainer:
	return _chat_scroll_container


func get_settings_panel() -> SettingsPanel:
	return _settings_panel_node


## 初始化编辑器依赖
func initialize_editor_dependencies(p_editor_filesystem: EditorFileSystem) -> void:
	if not p_editor_filesystem.filesystem_changed.is_connected(_on_filesystem_changed):
		p_editor_filesystem.filesystem_changed.connect(_on_filesystem_changed)


## 更新 UI 的整体状态
func update_ui_state(p_new_state: UIState, p_payload: String = "") -> void:
	current_state = p_new_state
	_status_label.text = p_payload if not p_payload.is_empty() else _get_default_status_text(p_new_state)
	
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
			
			if not p_payload.is_empty():
				_show_error_dialog(p_payload)


## 更新模型下拉列表的内容
func update_model_list(p_model_names: Array[String]) -> void:
	var current_msg: String = _status_label.text
	if not ("No Chat" in current_msg):
		update_ui_state(UIState.IDLE, "Ready")
	
	model_list = p_model_names
	_apply_model_filter()


## 当获取模型列表请求失败时调用
func get_model_list_request_failed(p_error_message: String) -> void:
	if is_first_init:
		update_ui_state(UIState.ERROR, p_error_message)
	else:
		update_ui_state(UIState.ERROR, "")
		_status_label.text = p_error_message
		_status_label.modulate = Color.RED
		is_first_init = true


## 根据文件名同步下拉选择框
func select_session_by_name(p_session_name: String) -> void:
	_update_session_selector()
	
	for i in range(_session_selector.get_item_count()):
		if _session_selector.get_item_text(i) == p_session_name:
			_session_selector.select(i)
			return


## 清空用户输入框
func clear_user_input() -> void:
	_user_input.clear()


## 更新对话轮数显示
func update_turn_display(p_current_turns: int, p_max_turns: int) -> void:
	if _chat_turn_display:
		_chat_turn_display.text = "Turns: %d / %d" % [p_current_turns, p_max_turns]
		
		if p_current_turns >= p_max_turns:
			_chat_turn_display.modulate = Color(1, 0.6, 0.2)
		else:
			_chat_turn_display.modulate = Color.WHITE


## 准备开始新的请求：结算上一轮
func prepare_for_new_request() -> void:
	_archived_total_usage.prompt += _current_turn_usage.prompt
	_archived_total_usage.completion += _current_turn_usage.completion
	_archived_total_usage.total += _current_turn_usage.total
	
	_current_turn_usage = { "prompt": 0, "completion": 0, "total": 0 }


## 更新 UI 界面的 Token 数据
func update_token_usage_display(p_usage: Dictionary) -> void:
	var p: int = p_usage.get("prompt_tokens", 0)
	var c: int = p_usage.get("completion_tokens", 0)
	
	if p < _current_turn_usage.prompt:
		p = _current_turn_usage.prompt
	if c < _current_turn_usage.completion:
		c = _current_turn_usage.completion
	
	var t: int = p_usage.get("total_tokens", p + c)
	
	_current_turn_usage = {
		"prompt": p,
		"completion": c,
		"total": t
	}
	
	var display_total: int = _archived_total_usage.total + t
	var display_prompt: int = _archived_total_usage.prompt + p
	var display_completion: int = _archived_total_usage.completion + c
	
	_current_token_usage.text = "Cost: %d (Sum: %d) | Prompt: %d | Compl: %d" % [
		t, 
		display_total,
		p,
		c
	]
	
	_current_token_usage.tooltip_text = (
		"Current Request:\n - Prompt: %d\n - Completion: %d\n - Total: %d\n\n" +
		"Session Total (Snowball):\n - Prompt: %d\n - Completion: %d\n - Total: %d"
	) % [p, c, t, display_prompt, display_completion, display_total]


## 重置 Token 显示
func reset_token_usage_display() -> void:
	_archived_total_usage = { "prompt": 0, "completion": 0, "total": 0 }
	_current_turn_usage = { "prompt": 0, "completion": 0, "total": 0 }
	
	_current_token_usage.text = "Token Cost: 0"
	_current_token_usage.tooltip_text = ""


## 显示一个确认/成功对话框
func show_confirmation(p_message: String) -> void:
	_error_dialog.title = "Notification"
	_error_dialog.dialog_text = p_message
	
	if _error_dialog.confirmed.is_connected(_on_delete_confirmed):
		_error_dialog.confirmed.disconnect(_on_delete_confirmed)
		_pending_delete_session_name = ""
	
	_error_dialog.popup_centered()


# --- Private Functions ---

func _get_default_status_text(p_state: UIState) -> String:
	match p_state:
		UIState.IDLE: return "Ready"
		UIState.CONNECTING: return "Connecting..."
		UIState.WAITING_RESPONSE: return "Waiting for LLM response..."
		UIState.RESPONSE_GENERATING: return "LLM is generating..."
		UIState.TOOLCALLING: return "Executing Tools..."
		UIState.ERROR: return "Error"
	return ""


func _show_error_dialog(p_msg: String) -> void:
	_error_dialog.title = "Error"
	_error_dialog.dialog_text = p_msg
	_error_dialog.popup_centered()


func _update_workspace_display(p_path: String) -> void:
	if p_path.is_empty():
		_workspace_label.text = "Please Set Workspace"
		_workspace_label.modulate = Color.GRAY
	else:
		_workspace_label.text = "Current Workspace: " + p_path
		_workspace_label.modulate = Color.WHITE


func _apply_model_filter() -> void:
	var filter_text: String = _model_name_filter_input.text.strip_edges().to_lower()
	var previously_selected: String = ""
	
	if _model_selector.selected != -1:
		previously_selected = _model_selector.get_item_text(_model_selector.selected)
	
	var filtered_models: Array[String] = []
	for model_name in model_list:
		if filter_text.is_empty() or model_name.to_lower().contains(filter_text):
			filtered_models.append(model_name)
	
	_model_selector.clear()
	if filtered_models.is_empty():
		_model_selector.add_item("No matching models found")
		_model_selector.disabled = true
		model_selection_changed.emit("")
	else:
		_model_selector.disabled = false
		for name in filtered_models:
			_model_selector.add_item(name)
		
		var new_selection_index: int = filtered_models.find(previously_selected)
		if new_selection_index != -1:
			_model_selector.select(new_selection_index)
			_on_model_selected(new_selection_index) 
		elif not filtered_models.is_empty():
			_model_selector.select(0)
			_on_model_selected(0)


func _update_session_selector() -> void:
	var archives: Array[String] = SessionStorage.get_session_list()
	var previously_selected: String = ""
	
	if _session_selector.selected != -1:
		previously_selected = _session_selector.get_item_text(_session_selector.selected)
	
	_session_selector.clear()
	
	if archives.is_empty():
		_session_selector.disabled = true
	else:
		_session_selector.disabled = false
		var new_selection_index: int = -1
		for i in range(archives.size()):
			var archive_name: String = archives[i]
			_session_selector.add_item(archive_name)
			
			if archive_name == previously_selected:
				new_selection_index = i
		
		if new_selection_index != -1:
			_session_selector.select(new_selection_index)


func _generate_default_filename(p_extension: String) -> String:
	var now: Dictionary = Time.get_datetime_dict_from_system(false)
	var timestamp_str: String = "chat_%d-%02d-%02d_%02d-%02d-%02d" % [now.year, now.month, now.day, now.hour, now.minute, now.second]
	return timestamp_str + p_extension


# --- Signal Callbacks ---

func _on_delete_chat_button_pressed() -> void:
	var selected_index: int = _session_selector.selected
	if selected_index == -1:
		show_confirmation("Please select a chat archive to delete.")
		return
	
	var archive_name: String = _session_selector.get_item_text(selected_index)
	
	_error_dialog.title = "Confirm Delete"
	_error_dialog.dialog_text = "Are you sure you want to delete '%s'?\n\nThis action cannot be undone." % archive_name
	
	_pending_delete_session_name = archive_name
	
	if not _error_dialog.confirmed.is_connected(_on_delete_confirmed):
		_error_dialog.confirmed.connect(_on_delete_confirmed)
	
	_error_dialog.popup_centered()


func _on_delete_confirmed() -> void:
	if _pending_delete_session_name.is_empty():
		return
	
	delete_chat_button_pressed.emit(_pending_delete_session_name)
	_pending_delete_session_name = ""


func _on_load_chat_button_pressed() -> void:
	var selected_index: int = _session_selector.selected
	if selected_index == -1:
		show_confirmation("Please select a chat archive to load.")
		return
	var archive_name: String = _session_selector.get_item_text(selected_index)
	load_chat_button_pressed.emit(archive_name)


func _on_new_chat_button_pressed() -> void:
	new_chat_button_pressed.emit()


func _on_reconnect_button_pressed() -> void:
	reconnect_button_pressed.emit()


func _on_model_selected(p_index: int) -> void:
	if _model_selector.get_item_count() > p_index and p_index >= 0:
		var model_name: String = _model_selector.get_item_text(p_index)
		model_selection_changed.emit(model_name)


func _on_model_name_filter_text_changed(_new_text: String) -> void:
	_apply_model_filter()


func _on_save_as_markdown_button_pressed() -> void:
	_file_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_file_dialog.clear_filters()
	_file_dialog.add_filter("*.md", "Markdown File")
	_file_dialog.current_dir = PluginPaths.SESSION_DIR
	_file_dialog.current_file = _generate_default_filename(".md")
	_file_dialog.popup_centered()


func _on_send_button_pressed() -> void:
	if current_state in [UIState.WAITING_RESPONSE, UIState.RESPONSE_GENERATING, UIState.TOOLCALLING]:
		stop_button_pressed.emit()
	elif current_state == UIState.IDLE or current_state == UIState.ERROR:
		var user_prompt: String = _user_input.text.strip_edges()
		if not user_prompt.is_empty():
			send_button_pressed.emit(user_prompt)


func _on_file_selected(p_path: String) -> void:
	save_as_markdown_button_pressed.emit(p_path)


func _on_settings_save_button_pressed() -> void:
	settings_save_button_pressed.emit()
	if _tab_container:
		_tab_container.current_tab = 0


func _on_filesystem_changed() -> void:
	_update_session_selector()


func _on_workspace_select_button_pressed() -> void:
	_workspace_file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_workspace_file_dialog.title = "Select Workspace Directory"
	var settings := ToolBox.get_plugin_settings()
	if not settings.workspace_path.is_empty():
		_workspace_file_dialog.current_dir = settings.workspace_path
	_workspace_file_dialog.popup_centered()


func _on_workspace_dir_selected(p_dir: String) -> void:
	workspace_changed.emit(p_dir)
	_update_workspace_display(p_dir)
