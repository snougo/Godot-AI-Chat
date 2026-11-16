@tool
class_name ReadonlyZoneConfig
extends Resource

## 写入管控配置资源
##
## 集中配置 AI 写操作的两道关卡：
## 1. 路径关卡：readonly_patterns 命中的路径一律禁写（extra_write_allowlist 可豁免）
## 2. 格式关卡：改写已有文本文件时，扩展名必须位于 editable_text_extensions
##
## 替代原先硬编码在 AiTool.PATH_BLACKLIST 与 edit_file_tool 中的
## EDITABLE_EXTENSIONS / EXTRA_WRITE_ALLOWLIST 常量。
## 每次 get_config() 都直接从磁盘加载，改完资源立即生效，无需重启插件。


# --- @export Vars ---

## 配置的唯一标识/名称
@export var config_name: String = "Write Guard"
## 配置的简短描述（用于 UI 显示或 Tooltip）
@export_multiline var description: String = "AI 写操作的管控区（禁写路径）与可写格式配置"

## 管控区：路径片断列表（片断语义 —— 路径中任意位置出现即命中）
## 例如 "/addons/" 会同时命中 "res://addons/x.gd" 与 "res://sub/addons/x.gd"；
## 前缀 "res://" 会被等价转换为 "/" 处理，因此写成 "res://addons/" 同样有效。
@export var readonly_patterns: Array[String] = [
	"/.git/",
	"/.import/",
	"/.godot/",
	"/android/",
	"/addons/",
]

## 显式豁免的路径前缀（完整前缀语义，如 "res://addons/poly_model/"）
## 命中即绕过 readonly_patterns，但格式关卡仍然生效。默认空 = 完全遵循 readonly_patterns。
@export var extra_write_allowlist: Array[String] = []

## 允许改写的文本类扩展名（不含点，大小写不敏感）
## 仅约束「改写已有文件」类工具（如 edit_file）；创建类工具使用各自的固定格式。
@export var editable_text_extensions: Array[String] = [
	"md", "txt", "json", "cfg", "csv", "glsl", "gdshader", "gd"
]


# --- Public Functions ---

## 获取配置（如果不存在则自动创建默认配置）
static func get_config() -> ReadonlyZoneConfig:
	var path: String = PluginPaths.READONLY_ZONE_CONFIG_PATH
	
	if ResourceLoader.exists(path):
		return ResourceLoader.load(path, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
	else:
		var config := ReadonlyZoneConfig.new()
		ResourceSaver.save(config, path)
		ToolBox.update_editor_filesystem(path)
		return config


## 返回命中的管控区片断；空字符串表示该路径不在管控区内（可写）
## [param p_path]: 目标路径，建议传入以 res:// 开头的路径
func get_blocked_pattern(p_path: String) -> String:
	if _is_path_allowlisted(p_path):
		return ""
	
	var check_path: String = _normalize_for_match(p_path)
	for raw_pattern: String in readonly_patterns:
		var pattern: String = _normalize_for_match(raw_pattern)
		if pattern.is_empty():
			continue
		if check_path.find(pattern) != -1:
			return raw_pattern
	
	return ""


## 路径是否可写（不在管控区内，或命中了豁免前缀）
func is_write_allowed(p_path: String) -> bool:
	return get_blocked_pattern(p_path).is_empty()


## 扩展名是否允许改写（传入带点或不带点均可，大小写不敏感）
func is_extension_editable(p_extension: String) -> bool:
	var ext: String = _normalize_extension(p_extension)
	if ext.is_empty():
		return false
	
	for raw_ext: String in editable_text_extensions:
		if _normalize_extension(raw_ext) == ext:
			return true
	
	return false


## 返回可直接展示的扩展名串（逗号分隔、小写、已去重）
func get_editable_extensions_text() -> String:
	var parts: PackedStringArray = PackedStringArray()
	
	for raw_ext: String in editable_text_extensions:
		var ext: String = _normalize_extension(raw_ext)
		if not ext.is_empty() and not parts.has(ext):
			parts.append(ext)
	
	return ", ".join(parts)


# --- Private Functions ---

# 路径匹配归一化：res:// 与反斜杠统一为 "/"，并补齐首尾斜杠
# 说明：首尾斜杠用于避免 "res://addons_test" 被误判为 "/addons/" 命中
func _normalize_for_match(p_text: String) -> String:
	var normalized: String = p_text.strip_edges().replace("res://", "/").replace("\\", "/")
	if normalized.is_empty():
		return ""
	if not normalized.begins_with("/"):
		normalized = "/" + normalized
	if not normalized.ends_with("/"):
		normalized += "/"
	
	return normalized


# 扩展名归一化：去空白、去前导点、转小写
func _normalize_extension(p_extension: String) -> String:
	return p_extension.strip_edges().trim_prefix(".").to_lower()


# 是否命中豁免前缀（完整前缀语义，不做片断匹配）
func _is_path_allowlisted(p_path: String) -> bool:
	var normalized: String = p_path.replace("\\", "/")
	
	for raw_prefix: String in extra_write_allowlist:
		var prefix: String = raw_prefix.strip_edges().replace("\\", "/")
		if prefix.is_empty():
			continue
		if normalized.begins_with(prefix):
			return true
	
	return false
