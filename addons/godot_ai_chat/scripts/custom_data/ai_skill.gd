@tool
class_name AiSkill
extends Resource

## The unique identifier/name for this skill (e.g., "Scene Builder")
@export var skill_name: String = ""

## A brief description of what this skill does (for UI/Tooltips)
@export_multiline var description: String = ""

## Path to the markdown file containing the system instructions/guidelines for this skill.
## The content of this file will be injected into the chat context.
@export_file("*.md", "*.txt") var instruction_file: String = ""

## List of tool script paths that constitute this skill.
@export_file("*.gd") var tools: Array[String] = []
