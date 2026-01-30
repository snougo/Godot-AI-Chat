# GDScript 风格指南 (Godot 4)

本指南基于 Godot 官方最佳实践，旨在确保生成的代码清晰、一致且易于维护。

## 1. 命名规范

| 元素类型 | 风格 | 示例 |
| :--- | :--- | :--- |
| **类名 (Class Name)** | PascalCase | `CharacterBody3D`, `MainMenu` |
| **节点名 (Node Name)** | PascalCase | `PlayerSprite`, `CollisionShape` |
| **变量 (Variable)** | snake_case | `health`, `move_speed` |
| **私有变量** | _snake_case | `_current_state`, `_cache` |
| **常量 (Constant)** | CONSTANT_CASE | `MAX_SPEED`, `GRAVITY` |
| **函数 (Function)** | snake_case | `get_player_position()`, `_on_timer_timeout()` |
| **信号 (Signal)** | snake_case (过去时) | `health_changed`, `game_over` |

## 2. 静态类型 (Static Typing)

在 Godot 4 中，**强烈建议**使用静态类型。它能显著提升性能并减少 Bug。

### 变量声明
```gdscript
# 推荐
var health: int = 100
var velocity: Vector3 = Vector3.ZERO
var target_node: Node3D = null

# 避免 (除非类型确实动态)
var data
```

### 函数签名
```gdscript
# 推荐
func calculate_damage(base_damage: float, multiplier: float) -> float:
    return base_damage * multiplier

# 避免
func calculate_damage(base_damage, multiplier):
    return base_damage * multiplier
```

### 自动推断
对于常量或显而易见的赋值，可以使用 `:=` 进行类型推断：
```gdscript
var name := "Player" # 推断为 String
```

## 3. 代码组织结构

脚本内部应遵循以下顺序，保持整洁：

1.  `@tool` (如果是工具脚本)
2.  `class_name`
3.  `extends`
4.  `# Docstring` (文档注释)
5.  `signal` 声明
6.  `enum` 定义
7.  `const` 定义
8.  `@export` 变量
9.  `@onready` 变量
10. `var` (Public)
11. `var` (Private, `_` 开头)
12. `func _init()`
13. `func _ready()`
14. `func _process()` / `_physics_process()`
15. Public 函数
16. Private 函数
17. 信号回调函数 (`_on_...`)

## 4. 信号连接

在 Godot 4 中，优先使用 `Callable` 语法，而不是字符串语法。

```gdscript
# 推荐 (Godot 4)
button.pressed.connect(_on_button_pressed)
timer.timeout.connect(_on_timer_timeout)

# 避免 (Godot 3 旧语法)
button.connect("pressed", self, "_on_button_pressed")
```

## 5. 注释

*   **文档注释**：使用 `##` 为导出的变量和公共函数编写文档，这样它们会显示在编辑器的帮助面板中。
*   **普通注释**：使用 `#` 解释复杂的逻辑块。

```gdscript
## 玩家的最大生命值
@export var max_health: int = 100
```
