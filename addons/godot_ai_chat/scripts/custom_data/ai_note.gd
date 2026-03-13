@tool
class_name AiNote
extends Resource

## Unique ID (incremental)
@export var id: int = 0

## Note title
@export var title: String = ""

## Created time
@export var created_time: String = ""

## Note content
@export_multiline var content: String = ""

## Note category (fixed options)
@export var category: String = "Development Log"

## Note importance level (1-5, 5 is highest)
@export var importance: int = 3

const VALID_CATEGORIES: Array[String] = ["Development Log", "Lessons Learned", "Best Practices"]
const MIN_IMPORTANCE: int = 1
const MAX_IMPORTANCE: int = 5


## Initialize created time
func _init() -> void:
	if created_time.is_empty():
		created_time = Time.get_datetime_string_from_system()


## Validate category is valid
func validate_category() -> bool:
	return category in VALID_CATEGORIES


## Validate importance range
func validate_importance() -> bool:
	return importance >= MIN_IMPORTANCE and importance <= MAX_IMPORTANCE


## Clamp importance to valid range
static func clamp_importance(value: int) -> int:
	return clampi(value, MIN_IMPORTANCE, MAX_IMPORTANCE)


## Check if category is valid (static)
static func is_valid_category(p_category: String) -> bool:
	return p_category in VALID_CATEGORIES


## Get valid categories (static)
static func get_valid_categories() -> Array[String]:
	return VALID_CATEGORIES
