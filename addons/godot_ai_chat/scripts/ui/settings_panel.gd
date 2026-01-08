@tool
class_name SettingsPanel
extends Control

## 负责管理插件的设置界面，包括加载、显示和保存用户配置。

# --- Signals ---

## 当用户点击保存按钮并且设置成功保存后发出
signal settings_saved
## 当请求关闭面板时发出
signal close_requested

# --- Enums ---

## 保存按钮的内部状态
enum SaveButtonState {
	IDLE,   ## 空闲状态
	SAVING  ## 正在保存状态
}

# --- Constants ---

## 插件设置资源文件的固定路径
const SETTINGS_PATH: String = "res://addons/godot_ai_chat/plugin_settings.tres"

# --- @onready Vars ---

@onready var _api_provider_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer/APIProviderLabel
@onready var _base_url_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer2/BaseUrlLabel
@onready var _api_key_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer3/APIKeyLabel
@onready var _tavily_api_key_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer7/TavilyAPIKeyLabel
@onready var _max_chat_turns_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer4/MaxChatTurnsLabel
@onready var _timeout_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer5/TimeoutLabel
@onready var _temperature_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer6/TemperatureLabel
@onready var _temperature_value_label: Label = $Panel/MarginContainer/VBoxContainer/HBoxContainer6/TemperatureValueLabel
@onready var _system_prompt_label: Label = $Panel/MarginContainer/VBoxContainer/SystemPromptLabel

@onready var _api_provider_options: OptionButton = $Panel/MarginContainer/VBoxContainer/HBoxContainer/APIProviderOptions
@onready var _base_url_input: LineEdit = $Panel/MarginContainer/VBoxContainer/HBoxContainer2/BaseUrlInput
@onready var _api_key_input: LineEdit = $Panel/MarginContainer/VBoxContainer/HBoxContainer3/APIKeyInput
@onready var _tavily_api_key_input: LineEdit = $Panel/MarginContainer/VBoxContainer/HBoxContainer7/TavilyAPIKeyInput
@onready var _max_chat_turns_value: SpinBox = $Panel/MarginContainer/VBoxContainer/HBoxContainer4/MaxChatTurnsValue
@onready var _timeout_value: SpinBox = $Panel/MarginContainer/VBoxContainer/HBoxContainer5/TimeoutValue
@onready var _temperature_value: HSlider = $Panel/MarginContainer/VBoxContainer/HBoxContainer6/TemperatureValue
@onready var _system_prompt_input: TextEdit = $Panel/MarginContainer/VBoxContainer/SystemPromptInput

@onready var _save_button: Button = $Panel/MarginContainer/VBoxContainer/CenterContainer/SaveButton

# --- Public Vars ---

## 持有加载后的设置资源对象
var settings_resource: PluginSettings

# --- Built-in Functions ---

func _ready() -> void:
	_api_provider_label.text = "API Provider:"
	_base_url_label.text = "Base Url:"
	_base_url_label.tooltip_text = "When using openRouter as API Service Provider, You should input https://openrouter.ai/api, not https://openrouter.ai"
	_base_url_input.placeholder_text = "LM Studio: http://127.0.0.1:1234"
	_api_key_label.text = "API Key(optional):"
	_api_key_label.tooltip_text = "When using LM Studio or Ollama, You don't need to provide an API Key."
	_tavily_api_key_label.text = "Tavily API Key(optional):"
	_tavily_api_key_label.tooltip_text = "Web Search need API Key to work."
	_max_chat_turns_label.text = "Max Chat Turns:"
	_timeout_label.text = "Timeout (sec):"
	_temperature_label.text = "Temperature:"
	_system_prompt_label.text = "System Prompt:"
	
	_temperature_value.value_changed.connect(_on_temperature_value_changed)
	_save_button.pressed.connect(_on_save_button_pressed)
	
	_api_provider_options.clear()
	_api_provider_options.add_item("OpenAI-Compatible")
	_api_provider_options.add_item("Local-AI-Service")
	_api_provider_options.add_item("ZhipuAI")
	_api_provider_options.add_item("Google Gemini")

	_load_and_display_settings()
	_update_ui(SaveButtonState.IDLE)

# --- Private Functions ---

## 根据新的状态更新 UI 元素
func _update_ui(_new_state: SaveButtonState) -> void:
	match _new_state:
		SaveButtonState.IDLE:
			_save_button.disabled = false
			_save_button.text = "Save and Close"
		SaveButtonState.SAVING:
			_save_button.disabled = true
			_save_button.text = "Saving..."


## 从文件加载设置，如果文件不存在则创建一个新的
func _load_and_display_settings() -> void:
	if ResourceLoader.exists(SETTINGS_PATH):
		settings_resource = load(SETTINGS_PATH)
	else:
		settings_resource = PluginSettings.new()
		ResourceSaver.save(settings_resource, SETTINGS_PATH)

	_populate_ui_from_resource()
	_update_ui(SaveButtonState.IDLE)


## 将从资源文件加载的设置值填充到各个 UI 控件中
func _populate_ui_from_resource() -> void:
	var _selected_index: int = -1
	for _i in range(_api_provider_options.item_count):
		if _api_provider_options.get_item_text(_i) == settings_resource.api_provider:
			_selected_index = _i
			break
	if _selected_index != -1:
		_api_provider_options.select(_selected_index)
	
	_base_url_input.text = settings_resource.api_base_url
	_api_key_input.text = settings_resource.api_key
	_tavily_api_key_input.text = settings_resource.tavily_api_key
	_max_chat_turns_value.value = settings_resource.max_chat_turns
	_timeout_value.value = settings_resource.network_timeout
	_temperature_value.value = settings_resource.temperature
	_on_temperature_value_changed(settings_resource.temperature)
	_system_prompt_input.text = settings_resource.system_prompt

# --- Signal Callbacks ---

func _on_temperature_value_changed(_value: float) -> void:
	_temperature_value_label.text = "%.2f" % _value


func _on_save_button_pressed() -> void:
	_update_ui(SaveButtonState.SAVING)
	await get_tree().create_timer(0.2).timeout
	
	settings_resource.api_provider = _api_provider_options.get_item_text(_api_provider_options.selected)
	settings_resource.api_base_url = _base_url_input.text
	settings_resource.api_key = _api_key_input.text
	settings_resource.tavily_api_key = _tavily_api_key_input.text
	settings_resource.max_chat_turns = int(_max_chat_turns_value.value)
	settings_resource.network_timeout = int(_timeout_value.value)
	settings_resource.temperature = _temperature_value.value
	settings_resource.system_prompt = _system_prompt_input.text
	
	if ResourceSaver.save(settings_resource, SETTINGS_PATH) == OK:
		settings_saved.emit()
	
	_update_ui(SaveButtonState.IDLE)
