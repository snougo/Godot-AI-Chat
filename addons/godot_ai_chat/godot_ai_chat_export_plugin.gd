@tool
extends EditorExportPlugin

## Godot AI Chat 导出自定义插件
##
## 本插件启用期间，导出项目时跳过插件自身目录下的所有文件。
## 本插件为纯编辑器辅助工具，与游戏运行无关，无需进入发行包。
## 由 plugin.gd（EditorPlugin）在 _enter_tree 时注册、_exit_tree 时注销。

# --- Constants ---

## 需要从导出中排除的插件根目录
const PLUGIN_EXPORT_ROOT: String = "res://addons/godot_ai_chat/"


# --- Virtual Interface（覆写基类虚接口） ---

## 返回本导出插件的标识名（导出器内部使用）
func _get_name() -> String:
	return "GodotAIChatExportPlugin"


## 对每个即将导出的文件回调；命中插件目录则跳过，使其不进入导出包
func _export_file(p_path: String, _p_type: String, _p_features: PackedStringArray) -> void:
	if p_path.begins_with(PLUGIN_EXPORT_ROOT):
		skip()
