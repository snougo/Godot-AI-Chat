@tool
class_name PluginPaths
extends RefCounted

## 插件路径常量类
##
## 集中管理插件中所有硬编码路径，便于维护和修改。

# --- Plugin Root ---

## 插件根目录
const PLUGIN_DIR: String = "res://addons/godot_ai_chat/"

# --- Configuration ---

## 插件设置资源文件路径
const SETTINGS_PATH: String = PLUGIN_DIR + "plugin_settings_config.tres"

# --- Data Storage ---

## 聊天会话存档目录
const SESSION_DIR: String = PLUGIN_DIR + "chat_sessions/"

# --- Skills ---

## 技能目录
const SKILLS_DIR: String = PLUGIN_DIR + "skills/"

# --- Assets ---

## 资源目录
const ASSETS_DIR: String = PLUGIN_DIR + "assets/"

## 代码高亮主题资源路径
const CODE_HIGHLIGHT_THEME: String = ASSETS_DIR + "code_hightlight.tres"

# --- Scenes ---

## 场景目录
const SCENE_DIR: String = PLUGIN_DIR + "scene/"

## ChatHub场景路径
const CHAT_HUB_SCENE: String = SCENE_DIR + "chat_hub.tscn"

## 聊天消息块场景路径
const CHAT_MESSAGE_BLOCK_SCENE: String = SCENE_DIR + "chat_message_block.tscn"


# --- Public Functions ---

## 根据工作区路径生成 Todo List 文件路径
## @param workspace_path 工作区根目录 (如 "res://project/")
## @return Todo List 资源文件完整路径（例如："res://project/todo_list.tres"）
static func get_todo_list_path(workspace_path: String) -> String:
	var dir := workspace_path if workspace_path.ends_with("/") else workspace_path + "/"
	return dir + "todo_list.tres"
