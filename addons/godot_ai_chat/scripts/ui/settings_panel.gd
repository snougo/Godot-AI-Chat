@tool
extends Control


# 当用户点击保存按钮并且设置成功保存后发出
signal settings_saved
# (原始代码中存在但未使用) 当请求关闭面板时发出
signal close_requested

# 定义UI的内部状态，主要用于控制保存按钮的显示和可交互性
enum SaveButtonState {IDLE, SAVING}

# 插件设置资源文件的固定路径
const SETTINGS_PATH = "res://addons/godot_ai_chat/plugin_settings.tres"

# 持有加载后的设置资源对象
var settings_resource: PluginSettings

# --- 场景节点引用 ---
@onready var api_provider_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer/APIProviderLabel
@onready var base_url_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer2/BaseUrlLabel
@onready var api_key_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer3/APIKeyLabel
@onready var tavily_api_key_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer7/TavilyAPIKeyLabel
@onready var max_chat_turns_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer4/MaxChatTurnsLabel
@onready var timeout_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer5/TimeoutLabel
@onready var temperature_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer6/TemperatureLabel
@onready var temperature_value_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer6/TemperatureValueLabel
@onready var system_prompt_label: Label = $Panel/MarginContainer/VBoxContainer/SystemPromptLabel

@onready var api_provider_options: OptionButton = $Panel/MarginContainer/VBoxContainer/HBoxContainer/APIProviderOptions
@onready var base_url_input: LineEdit = $Panel/MarginContainer/VBoxContainer/HBoxContainer2/BaseUrlInput
@onready var api_key_input: LineEdit = $Panel/MarginContainer/VBoxContainer/HBoxContainer3/APIKeyInput
@onready var tavily_api_key_input: LineEdit = $Panel/MarginContainer/VBoxContainer/HBoxContainer7/TavilyAPIKeyInput
@onready var max_chat_turns_value: SpinBox = $Panel/MarginContainer/VBoxContainer/HBoxContainer4/MaxChatTurnsValue
@onready var timeout_value: SpinBox = $Panel/MarginContainer/VBoxContainer/HBoxContainer5/TimeoutValue
@onready var temperature_value: HSlider = $Panel/MarginContainer/VBoxContainer/HBoxContainer6/TemperatureValue
@onready var system_prompt_input: TextEdit = $Panel/MarginContainer/VBoxContainer/SystemPromptInput

@onready var save_button: Button = $Panel/MarginContainer/VBoxContainer/CenterContainer/SaveButton


func _ready() -> void:
	# 初始化UI标签的静态文本
	api_provider_label.text = "API Provider:"
	base_url_label.text = "Base Url:"
	base_url_label.tooltip_text = "When using openRouter as API Service Provider, You should input https://openrouter.ai/api, not https://openrouter.ai"
	base_url_input.placeholder_text = "LM Studio: http://127.0.0.1:1234"
	api_key_label.text = "API Key(optional):"
	api_key_label.tooltip_text = "When using LM Studio or Ollama, You don't need to provide an API Key."
	tavily_api_key_label.text = "Tavily API Key(optional):"
	tavily_api_key_label.tooltip_text = "Web Search need API Key to work."
	max_chat_turns_label.text = "Max Chat Turns:"
	timeout_label.text = "Timeout (sec):"
	temperature_label.text = "Temperature:"
	system_prompt_label.text = "System Prompt:"
	
	# 连接UI控件的信号
	temperature_value.value_changed.connect(_on_temperature_value_changed)
	save_button.pressed.connect(_on_save_button_pressed)
	
	# 初始化API提供商下拉选项
	api_provider_options.clear()
	api_provider_options.add_item("OpenAI-Compatible")
	api_provider_options.add_item("Local-AI-Service")
	api_provider_options.add_item("ZhipuAI")
	api_provider_options.add_item("Google Gemini")

	
	# 加载现有设置并显示在UI上
	_load_and_display_settings()
	# 设置初始UI状态
	_update_ui(SaveButtonState.IDLE)


#==============================================================================
# ## 内部函数 ##
#==============================================================================

# 根据新的状态更新UI元素（主要是保存按钮）
func _update_ui(_new_state: SaveButtonState) -> void:
	match _new_state:
		SaveButtonState.IDLE:
			save_button.disabled = false
			save_button.text = "Save and Close"
		SaveButtonState.SAVING:
			save_button.disabled = true
			save_button.text = "Saving..."


# 从文件加载设置，如果文件不存在则创建一个新的
func _load_and_display_settings() -> void:
	if ResourceLoader.exists(SETTINGS_PATH):
		settings_resource = load(SETTINGS_PATH)
	else:
		settings_resource = PluginSettings.new()
		ResourceSaver.save(settings_resource, SETTINGS_PATH)

	_populate_ui_from_resource()
	_update_ui(SaveButtonState.IDLE)


# 将从资源文件加载的设置值填充到各个UI控件中
func _populate_ui_from_resource() -> void:
	# 设置API Provider下拉菜单的选中项
	var selected_index: int = -1
	for i in range(api_provider_options.item_count):
		if api_provider_options.get_item_text(i) == settings_resource.api_provider:
			selected_index = i
			break
	if selected_index != -1:
		api_provider_options.select(selected_index)
	
	# 填充其他输入控件
	base_url_input.text = settings_resource.api_base_url
	api_key_input.text = settings_resource.api_key
	tavily_api_key_input.text = settings_resource.tavily_api_key
	max_chat_turns_value.value = settings_resource.max_chat_turns
	timeout_value.value = settings_resource.network_timeout
	temperature_value.value = settings_resource.temperature
	self._on_temperature_value_changed(settings_resource.temperature) # 更新温度标签显示
	system_prompt_input.text = settings_resource.system_prompt


#==============================================================================
# ## 信号回调函数 ##
#==============================================================================

# 当温度滑块的值改变时，更新旁边的标签以显示精确数值
func _on_temperature_value_changed(_value: float):
	temperature_value_label.text = "%.2f" % _value


# 当保存按钮被点击时执行
func _on_save_button_pressed():
	# 更新UI到“保存中”状态，提供视觉反馈
	_update_ui(SaveButtonState.SAVING)
	# 添加一个短暂延迟，确保用户能看到"Saving..."的文本变化
	await get_tree().create_timer(0.2).timeout
	# 从UI控件读取值并更新到资源对象中
	settings_resource.api_provider = api_provider_options.get_item_text(api_provider_options.selected)
	settings_resource.api_base_url = base_url_input.text
	settings_resource.api_key = api_key_input.text
	settings_resource.tavily_api_key = tavily_api_key_input.text
	settings_resource.max_chat_turns = int(max_chat_turns_value.value)
	settings_resource.network_timeout = int(timeout_value.value)
	settings_resource.temperature = temperature_value.value
	settings_resource.system_prompt = system_prompt_input.text
	# 保存资源到文件
	if ResourceSaver.save(settings_resource, SETTINGS_PATH) == OK:
		emit_signal("settings_saved")
	# 操作完成后，将UI状态恢复为空闲
	_update_ui(SaveButtonState.IDLE)
