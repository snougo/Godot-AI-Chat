# GDScript Coding Skill: Style Guide & Best Practices

## 1. Core Philosophy
- **Readability**: Code is read much more often than it is written. Prioritize clarity over brevity.
- **Godot 4.x Native**: Fully leverage Godot 4 features (Typed Arrays, callables, `await`, `super`).
- **Safety**: Use static typing to prevent runtime errors and improve editor autocompletion.

## 2. Naming Conventions

| Element | Style | Example |
| :--- | :--- | :--- |
| **Classes / Nodes** | `PascalCase` | `PlayerController`, `HealthBar` |
| **Variables** | `snake_case` | `current_health`, `is_active` |
| **Functions** | `snake_case` | `calculate_damage()`, `_on_timer_timeout()` |
| **Constants / Enums** | `SCREAMING_SNAKE` | `MAX_SPEED`, `STATE_IDLE` |
| **Private Members** | `_snake_case` | `_internal_cache`, `_update_physics()` |
| **Signals** | `snake_case` (past tense) | `health_changed`, `level_completed` |

## 3. Type Safety (Strict Typing)
**Rule**: Always use static typing. It improves performance and refactoring safety.

### Variables
```gdscript
# Bad
var health = 100
var velocity = Vector2.ZERO

# Good
var health: int = 100
var velocity: Vector2 = Vector2.ZERO

# Acceptable (Inference) - Only when type is unambiguous
var velocity := Vector2.ZERO
```

### Functions
Always define return types, use `void` if nothing is returned.
```gdscript
# Bad
func take_damage(amount):
    health -= amount

# Good
func take_damage(amount: int) -> void:
    health -= amount
    
func get_health_ratio() -> float:
    return float(health) / max_health
```

### Arrays & Dictionaries
Use Typed Arrays in Godot 4.
```gdscript
# Bad
var items = []

# Good
var items: Array[String] = []
```

## 4. Code Structure & Organization
Organize script members in this specific order to maintain consistency:

1.  `tool` keyword (if applicable)
2.  `class_name`
3.  `extends`
4.  **Docstring** (`## Description`)
5.  **Signals** (`signal ...`)
6.  **Enums** (`enum ...`)
7.  **Constants** (`const ...`)
8.  **Exported Variables** (`@export var ...`)
9.  **Public Variables** (`var ...`)
10. **Private Variables** (`var _...`)
11. **Onready Variables** (`@onready var ...`)
12. **Built-in Virtual Methods** (`_init`, `_ready`, `_process`)
13. **Public Methods**
14. **Private Methods**
15. **Signal Callbacks** (`_on_...`)

## 5. Modern Syntax (Godot 4.x)

### Exports
Use `@export` annotation, and group them for editor clarity.
```gdscript
@export_group("Movement")
@export var speed: float = 200.0
@export var jump_force: float = 400.0

@export_subgroup("Dash")
@export var can_dash: bool = true
```

### Signals
Use `await` instead of `yield`. Use Callable for connections.
```gdscript
# Connection
button.pressed.connect(_on_button_pressed)

# Await
await get_tree().create_timer(1.0).timeout
```

### Inheritance
Use `super` keyword.
```gdscript
func _ready() -> void:
    super._ready() # Calls parent's _ready
    _initialize()
```

## 6. Documentation (Docstrings)
Use `##` to generate in-editor documentation for logic that other developers (or AI) might use.