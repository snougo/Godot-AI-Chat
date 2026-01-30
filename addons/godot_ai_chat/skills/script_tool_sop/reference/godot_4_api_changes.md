# Godot 4 API 变更备忘录

本文件列出了从 Godot 3 迁移到 Godot 4 时最常见且容易出错的 API 变更。AI 在生成代码时**必须**遵守 Godot 4 的标准。

## 1. 核心节点重命名

| Godot 3 | Godot 4 | 备注 |
| :--- | :--- | :--- |
| `Spatial` | **`Node3D`** | 3D 根节点基类 |
| `KinematicBody` | **`CharacterBody3D`** | 3D 角色物理 |
| `KinematicBody2D` | **`CharacterBody2D`** | 2D 角色物理 |
| `RigidBody` | **`RigidBody3D`** | 3D 刚体 |
| `Position2D` | **`Marker2D`** | 2D 定位点 |
| `Position3D` | **`Marker3D`** | 3D 定位点 |
| `Navigation2D` | **`Node2D`** | 导航系统已重构，不再有专门的 Navigation2D 节点 |

## 2. 物理移动 (CharacterBody)

`move_and_slide()` 的用法发生了重大变化。

**Godot 3:**
```gdscript
velocity = move_and_slide(velocity, Vector3.UP)
```

**Godot 4:**
```gdscript
# velocity 现在是 CharacterBody 的内置属性
velocity.y += gravity * delta
move_and_slide() # 无参数，自动使用内置 velocity
# 碰撞结果通过 get_slide_collision() 获取
```

## 3. Tween (补间动画)

`Tween` 节点已不存在，Godot 4 改为提供了一个 `Tween` 类来直接方便的在代码中使用补间动画。具体使用方式请查阅API文档。

**Godot 3:**
```gdscript
$Tween.interpolate_property(self, "position", ...)
$Tween.start()
```

**Godot 4:**
```gdscript
var tween = get_tree().create_tween()
tween.tween_property($Sprite, "modulate", Color.RED, 1.0)
tween.tween_property($Sprite, "scale", Vector2(), 1.0)
tween.tween_callback($Sprite.queue_free)
```

## 4. 文件访问 (FileAccess)

`File` 类已被移除，使用 `FileAccess` 静态方法。

**Godot 3:**
```gdscript
var f = File.new()
f.open("res://data.txt", File.READ)
```

**Godot 4:**
```gdscript
var file = FileAccess.open("res://data.txt", FileAccess.READ)
if file:
	var content = file.get_as_text()
```

## 5. 随机数

全局随机函数已更新。

*   `rand_range(min, max)` -> **`randf_range(min, max)`** (浮点) 或 **`randi_range(min, max)`** (整数)
*   `randomize()` 仍然可用，但 Godot 4 默认会自动随机化种子。

## 6. 信号 (Signals)

*   **定义**: `signal my_signal(value: int)` (支持类型标注)
*   **发射**: `my_signal.emit(10)` (推荐) 或 `emit_signal("my_signal", 10)`
*   **连接**: `my_signal.connect(_on_callback)`

## 7. 导出变量 (@export)

语法简化：

**Godot 3:**
```gdscript
export(int) var speed = 10
export(String, FILE) var path
```

**Godot 4:**
```gdscript
@export var speed: int = 10
@export_file var path: String
@export_range(0, 100) var health: int
```
