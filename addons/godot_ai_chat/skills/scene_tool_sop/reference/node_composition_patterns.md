# 节点组合模式 (Node Composition Patterns)

在 Godot 中，通过组合不同的节点来构建复杂功能是核心设计哲学。以下是常见场景的标准节点层级结构。

## 1. 3D 角色 (CharacterBody3D)

用于玩家、NPC 或怪物。

```text
CharacterBody3D (Root) - 脚本: player.gd
 ├── CollisionShape3D  - 形状: CapsuleShape3D
 ├── MeshInstance3D    - 可视化模型 (通常作为子节点或来自 .glb)
 ├── Camera3D          - 摄像机 (如果是第一/第三人称)
 └── Node3D (Head/Pivot) - 用于控制视角的旋转中心
```

## 2. 2D 角色 (CharacterBody2D)

用于平台跳跃、俯视视角游戏角色。

```text
CharacterBody2D (Root) - 脚本: player_2d.gd
 ├── CollisionShape2D  - 形状: CapsuleShape2D 或 RectangleShape2D
 ├── Sprite2D          - 角色贴图 (或 AnimatedSprite2D)
 └── Camera2D          - 摄像机
```

## 3. UI 界面 (User Interface)

UI 应当使用 `Control` 节点及其子类，并充分利用容器进行自动布局。

**主菜单示例:**
```text
Control (Root) - Layout: Full Rect
 ├── TextureRect (Background) - Layout: Full Rect
 └── CenterContainer          - Layout: Full Rect
      └── VBoxContainer       - 垂直排列按钮
           ├── Label (Title)
           ├── Button (Start)
           ├── Button (Settings)
           └── Button (Quit)
```

**HUD (抬头显示) 示例:**
```text
CanvasLayer (Root) - 确保 UI 始终覆盖在游戏画面之上
 └── Control (HUD_Root) - Layout: Full Rect
      ├── MarginContainer - 设置边距
      │    └── HBoxContainer (Top Bar)
      │         ├── TextureProgressBar (Health)
      │         └── Label (Score)
      └── VBoxContainer (Inventory) - 位于右下角等位置
```

## 4. 3D 静态环境 (StaticBody3D)

用于地板、墙壁、障碍物。

```text
StaticBody3D (Root)
 ├── CollisionShape3D - 物理碰撞形状 (Box, ConcavePolygon 等)
 └── MeshInstance3D   - 视觉模型
```

## 5. 触发器区域 (Area3D / Area2D)

用于检测进入区域、伤害判定、拾取物品。

```text
Area3D (Root)
 ├── CollisionShape3D - 触发范围
 └── MeshInstance3D   - (可选) 视觉提示，如半透明球体
```

## 关键原则

1.  **单一职责**: 根节点决定了该场景的主要功能（移动、碰撞、UI）。
2.  **Owner 设置**: 在编辑器插件中动态创建节点树时，必须将所有子节点的 `owner` 设置为场景根节点，否则它们无法被保存到 `.tscn` 文件中。
3.  **分离逻辑**: 尽量将独立的逻辑（如武器系统、背包系统）封装为独立的场景或节点，通过 `Instantiate` 组合进来。
