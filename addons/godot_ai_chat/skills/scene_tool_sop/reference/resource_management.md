# 资源管理规范 (Resource Management)

在 Godot 中，正确管理资源（Resource）与节点（Node）的关系对于项目的可维护性至关重要。

## 1. 内置资源 vs 外部资源

*   **外部资源 (External, .tres/.tscn)**:
    *   **推荐场景**: 复用性高的资源（如通用的材质、脚本、子场景、Tileset）。
    *   **优点**: 修改一处，所有引用的地方都会更新；利于版本控制。
    *   **操作**: 使用 `load("res://path/to/resource.tres")` 加载。

*   **内置资源 (Built-in, Sub-resource)**:
    *   **推荐场景**: 仅属于特定场景且不需要复用的数据（如关卡特定的碰撞形状、临时动画曲线）。
    *   **优点**: 文件数量少，管理简单。
    *   **缺点**: 难以在其他地方复用。

## 2. 场景实例化 (Instantiation)

在代码中动态创建物体时，通常使用 `PackedScene`。

```gdscript
# 1. 预加载 (推荐，性能更好)
const BULLET_SCENE = preload("res://bullet.tscn")

func shoot():
    # 2. 实例化
    var bullet = BULLET_SCENE.instantiate()
    
    # 3. 添加到场景树 (通常添加到当前场景根节点或特定的容器节点)
    get_tree().current_scene.add_child(bullet)
    
    # 4. 设置初始状态
    bullet.global_position = global_position
```

## 3. 场景唯一名称 (Scene Unique Nodes)

Godot 4 引入了“场景唯一名称”（Scene Unique Names），允许在脚本中快速访问特定节点，而无需关心层级结构。

*   **编辑器操作**: 右键节点 -> 勾选 "Access as Unique Name" (节点名旁会出现 `%` 符号)。
*   **脚本访问**:
    ```gdscript
    # 无论 Player 在层级中多深，只要它是 Unique Name
    var player = %Player 
    # 等同于 get_node("%Player")
    ```
*   **AI 建议**: 在构建复杂 UI 或关卡时，如果某个节点（如 `ScoreLabel`）需要被频繁访问，建议将其设置为 Unique Name。

## 4. 资源路径规范

*   所有路径必须以 `res://` 开头。
*   文件名推荐使用 `snake_case` (如 `player_controller.gd`)。
*   避免使用绝对路径（如 `C:/Users/...`），这会导致项目在其他电脑上无法运行。

## 5. 依赖管理

*   **移动文件**: 务必在 Godot 编辑器的“文件系统”面板中移动或重命名文件。编辑器会自动更新所有引用该文件的依赖关系。
*   **AI 操作**: AI 工具目前主要通过路径操作。如果 AI 需要重构文件结构，应优先使用 Godot 提供的重命名/移动工具（如果可用），或者在操作后提醒用户检查依赖。
