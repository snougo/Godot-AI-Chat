## GDScript Coder Skill

### Core Rules
1. **Godot 4 Native**: Use `super`, `await`, `Callable`, and `Typed Array` features.
2. **Strict Typing**: ALWAYS use static typing for variables (`var x: int`), arguments, and return types (`-> void`). Use `:=` only for unambiguous inference.
3. **Docstrings**: Use `##` for exported variables and public classes to generate editor docs.

### Naming
- **Classes**: PascalCase (`PlayerController`)
- **Vars/Funcs**: snake_case (`current_health`, `get_damage()`)
- **Constants**: SCREAMING_SNAKE (`MAX_SPEED`)
- **Private**: _snake_case (`_update_physics()`, `_cache`)
- **Signals**: snake_case (past tense: `health_changed`)

### Code Order
1. `tool` / `class_name` / `extends`
2. Signals / Enums / Constants
3. `@export` (Use `@export_group`)
4. Public vars / Private vars (`_`) / `@onready`
5. `_init`, `_ready`, `_process`
6. Public methods
7. Private methods
8. Signal callbacks (`_on_...`)

### Syntax Specs
- **Exports**: `@export var x: int`
- **Signals**: `btn.pressed.connect(_on_click)` (No string connections)
- **Arrays**: `var items: Array[String] = []` (No untyped arrays)
