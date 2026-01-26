@tool
class_name AiSkill
extends Resource

## AI 技能定义资源
##
## 定义了一个“技能”，包含描述、系统指令文件以及相关的工具脚本。

# --- @export Vars ---

## 技能的唯一标识/名称 (例如 "Scene Builder")
@export var skill_name: String = ""

## 技能的简短描述 (用于 UI 显示或 Tooltip)
@export_multiline var description: String = ""

## 包含技能系统指令/指南的 Markdown 文件路径
## 该文件的内容将被注入到聊天上下文中。
@export_file("*.md", "*.txt") var instruction_file: String = ""

## 构成此技能的工具脚本路径列表
@export_file("*.gd") var tools: Array[String] = []
