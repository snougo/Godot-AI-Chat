@tool
class_name AIChatLogger
extends RefCounted

## 全局日志管理器 (AIChatLogger)
## 支持独立的日志通道开关

# --- Constants ---

const FLAG_DEBUG: int = 1
const FLAG_INFO: int  = 2
const FLAG_WARN: int  = 4
const FLAG_ERROR: int = 8

# --- Settings ---

## 当前激活的日志标记 (位掩码)
## 默认全开: 1|2|4|8 = 15
static var current_flags: int = 8


# --- Public Functions ---

static func debug(message: String, module: String = "Core") -> void:
	if current_flags & FLAG_DEBUG:
		_print_formatted(message, module, "DEBUG", Color.GRAY)

static func info(message: String, module: String = "Core") -> void:
	if current_flags & FLAG_INFO:
		_print_formatted(message, module, "INFO", Color.WHITE)

static func warn(message: String, module: String = "Core") -> void:
	if current_flags & FLAG_WARN:
		_print_formatted(message, module, "WARN", Color.ORANGE)

static func error(message: String, module: String = "Core") -> void:
	if current_flags & FLAG_ERROR:
		_print_formatted(message, module, "ERROR", Color.RED)

## 设置位掩码
static func set_flags(flags: int) -> void:
	current_flags = flags


# --- Private Functions ---

static func _print_formatted(msg: String, module: String, level_tag: String, color: Color) -> void:
	var time = Time.get_time_dict_from_system()
	var time_str = "%02d:%02d:%02d" % [time.hour, time.minute, time.second]
	
	if Engine.is_editor_hint():
		var color_hex = color.to_html()
		print_rich("[color=#888888][%s][/color][color=%s][%s][/color][b][%s][/b] %s" % [time_str, color_hex, level_tag, module, msg])
	else:
		print("[%s][%s][%s] %s" % [time_str, level_tag, module, msg])
