class_name AIChatLogger
extends RefCounted

## 全局日志管理器 (AIChatLogger)
## 支持独立的日志通道开关


# --- Constants ---

## 调试级日志位
const FLAG_DEBUG: int = 1
## 信息级日志位
const FLAG_INFO: int = 2
## 警告级日志位
const FLAG_WARN: int = 4
## 错误级日志位
const FLAG_ERROR: int = 8


# --- Settings ---

## 当前激活的日志标记 (位掩码)
## 默认只开启 ERROR 通道，避免编辑器启动阶段的日志刷屏
static var current_flags: int = FLAG_ERROR


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

# 格式化并输出日志
# [param p_msg]: 日志消息
# [param p_module]: 模块名称
# [param p_level_tag]: 级别标签
# [param p_color]: 显示颜色
static func _print_formatted(p_msg: String, p_module: String, p_level_tag: String, p_color: Color) -> void:
	var time_dict: Dictionary = Time.get_time_dict_from_system()
	var time_str: String = "%02d:%02d:%02d" % [time_dict.hour, time_dict.minute, time_dict.second]
	
	if Engine.is_editor_hint():
		var color_hex: String = p_color.to_html()
		print_rich("[color=#888888][%s][/color][color=%s][%s][/color][b][%s][/b] %s" % [time_str, color_hex, p_level_tag, p_module, p_msg])
	else:
		print("[%s][%s][%s] %s" % [time_str, p_level_tag, p_module, p_msg])
