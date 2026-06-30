# edit_scene 工具使用指南

## 操作类型（action）

| action | 功能 | 必填参数 |
|--------|------|---------|
| `add_node` | 在指定父节点下创建新节点 | `parent_path`, `node_class` |
| `delete_node` | 删除指定节点 | `node_path` |
| `move_node` | 将节点移动到另一个父节点下 | `node_path`, `parent_path` |

---

## 参数详解

### `node_path` — 节点路径

用于定位要操作的目标节点，支持以下格式：

| 格式 | 示例 | 说明 |
|------|------|------|
| `.` | `"."` | 场景根节点 |
| `NodeName` | `"Player"` | 直接节点名（仅在场景内唯一时可用） |
| `Parent/Child` | `"Player/Body/Sprite"` | **推荐** — 从根节点起的相对路径 |

> **前置要求**：使用 `edit_scene` 前必须先调用 `open_file` 打开目标场景文件。

> 编辑前先用 `get_edited_scene` 查看当前场景结构，可获取所有可用节点路径。

---

### `parent_path` — 父节点路径

用于指定操作的目标父节点（`add_node` 和 `move_node` 使用）。

格式与 `node_path` 一致，默认为根节点 `"."`。

---

### `node_class` — 节点类名（仅 `add_node` 使用）

支持两种格式：

| 格式 | 示例 | 说明 |
|------|------|------|
| **类名** | `"Node3D"`, `"Sprite2D"`, `"Control"`, `"Button"` | Godot 内置节点类型 |
| **场景文件路径** | `"res://scenes/player.tscn"` | **实例化已有场景文件**作为子节点 |

| 常用节点类型速查 | |
|------------------|--|
| 3D 节点 | `Node3D`, `MeshInstance3D`, `StaticBody3D`, `CharacterBody3D`, `Camera3D`, `DirectionalLight3D` |
| 2D 节点 | `Node2D`, `Sprite2D`, `Area2D`, `CharacterBody2D`, `Camera2D`, `TileMap` |
| UI 节点 | `Control`, `Panel`, `Label`, `Button`, `TextureRect`, `VBoxContainer`, `HBoxContainer` |
| 其他 | `AnimationPlayer`, `AudioStreamPlayer3D`, `Timer`, `CollisionShape3D` |

---

### `node_name` — 新节点名称（仅 `add_node` 使用，可选）

- 未指定时自动生成默认名称（如 `NewNode`）
- **建议显式命名**，使用语义化名称且首字母大写（如 `Background`, `PlayerBody`, `HealthBar`）

---

## 操作示例

### ✅ 添加节点

```
action: "add_node"
parent_path: "."
node_class: "Sprite2D"
node_name: "Background"
```

### ✅ 添加子节点到指定父节点下

```
action: "add_node"
parent_path: "Player/Body"
node_class: "CollisionShape3D"
node_name: "Hitbox"
```

### ✅ 实例化已有场景

```
action: "add_node"
parent_path: "Main"
node_class: "res://scenes/enemies/goblin.tscn"
```

### ✅ 删除节点

```
action: "delete_node"
node_path: "Player/Body/TempEffect"
```

### ✅ 移动节点

```
action: "move_node"
node_path: "HUD/ScoreLabel"
parent_path: "MainUI/TopBar"
```

---

## 注意事项

- **不能删除根节点**（`node_path="."` 不允许删除）
- **不能移动根节点**
- **不能将节点移动到它自己的子节点中**（会检测循环依赖）
- 操作成功后工具会自动返回**更新后的场景树结构**，便于确认结果
- 如需**查看节点属性**，请使用 `get_scene_node_properties`；如需**设置节点属性**，请使用 `set_scene_node_properties`（参考 `scene_node_params_guide.md`）
