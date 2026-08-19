@tool
class_name MainAgentToolConfig
extends Resource

## Main-Agent 工具配置资源
##
## 定义了 Main-Agent 可用的核心工具集。
## 通过 .tres 资源文件可视化配置，替代原先硬编码在 ToolRegistry 中的路径常量。

# --- @export Vars ---

## 配置的唯一标识/名称 (例如 "Main Agent Tools")
@export var config_name: String = "Main Agent Tools"

## 配置的简短描述 (用于 UI 显示或 Tooltip)
@export_multiline var description: String = "Main-Agent 的核心工具集配置"

## Main-Agent 可用的工具脚本路径列表
@export_file("*.gd") var tool_scripts: Array[String] = []


# --- Public Functions ---

## 获取工具配置（如果不存在则自动创建默认配置）
static func get_config() -> MainAgentToolConfig:
	var path: String = PluginPaths.MAIN_AGENT_TOOL_CONFIG_PATH
	if ResourceLoader.exists(path):
		return ResourceLoader.load(path, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
	else:
		var config := MainAgentToolConfig.new()
		config.tool_scripts = _get_default_tool_scripts()
		ResourceSaver.save(config, path)
		ToolBox.update_editor_filesystem(path)
		return config


# --- Private Functions ---

# 默认工具列表（仅在配置文件缺失时作为兜底模板）
static func _get_default_tool_scripts() -> Array[String]:
	return [
		"res://addons/godot_ai_chat/scripts/tools/file_tool/read_file_tool.gd",
		"res://addons/godot_ai_chat/scripts/tools/default_tool/list_folder_tool.gd",
		"res://addons/godot_ai_chat/scripts/tools/search_tool/fetch_web_content_tool.gd",
		"res://addons/godot_ai_chat/scripts/tools/search_tool/search_web_tool.gd",
		"res://addons/godot_ai_chat/scripts/tools/search_tool/search_godot_api_tool.gd",
		"res://addons/godot_ai_chat/scripts/tools/search_tool/find_code_references_tool.gd",
		"res://addons/godot_ai_chat/scripts/tools/memory_tool/add_memory_tool.gd",
		"res://addons/godot_ai_chat/scripts/tools/memory_tool/delete_memory_tool.gd",
		"res://addons/godot_ai_chat/scripts/tools/memory_tool/search_memories_tool.gd",
	]
