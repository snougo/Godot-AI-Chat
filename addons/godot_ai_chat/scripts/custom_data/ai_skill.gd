@tool
class_name AiSkill
extends Resource

## 技能的唯一标识符 (例如: "web_surfer")
## LLM 将使用此名称来调用 manage_skills 工具。
@export var skill_name: String = ""

## 简短描述，用于告诉 LLM 这个技能是做什么的。
## 例如: "Access internet for documentation and tutorials."
@export_multiline var description: String = ""

## 激活此技能时要加载的工具脚本列表。
## 请将 scripts/tools/ 下的 .gd 文件拖拽至此。
@export var tools: Array[GDScript] = []

## 激活技能后注入的 System Instructions (行为准则)。
## 例如: "Always check parent before adding node."
@export_multiline var system_instructions: String = ""

## (可选) 图标
@export var icon: Texture2D
