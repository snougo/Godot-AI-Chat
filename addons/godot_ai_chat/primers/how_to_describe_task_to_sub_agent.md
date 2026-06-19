# Sub-Agent 任务描述指南

## 概述
本文档指导主Agent（Main-Agent）在通过 `create_sub_agent` 工具向 Sub-Agent 发布任务时，使用标准化的格式组织 `task_description` 参数，以提高任务传达的准确性和执行效率。

## 通用原则
1. **结构化**：每个任务描述应包含清晰的段落分区，各部分之间用空行分隔。
2. **可视化**：层级关系使用树状符号描述；批量数据使用 Markdown 表格描述。
3. **明确性**：避免模糊描述，给出具体数值、路径和类型。

---

## 一、Scene Builder（场景构建）

### 格式规范

任务描述应依次包含以下三个部分：

#### 1. 场景概述
用一段文字简要说明场景的用途、核心需求和特殊要求。

#### 2. 场景树结构
使用树状符号（`└─`、`├─`、`│`）描述节点层级关系，格式为：
```
└─ <节点名> (<节点类型>)
   ├─ <子节点名> (<节点类型>)
   │  └─ <孙节点名> (<节点类型>)
   └─ <子节点名> (<节点类型>)
```

#### 3. 节点属性配置
使用 Markdown 表格列出需要设置的节点属性，表格用三个反引号 + `markdown` 包裹：

```markdown
| node_path | property_name | value |
|-----------|--------------|-------|
| <节点路径> | <属性名> | <属性值> |
```

### 完整示例

```
## 场景概述
创建一个简单的 3D 场景，包含一个带碰撞的地面、一个玩家角色和一盏方向光。

## 场景树结构
└─ GameLevel (Node3D)
   ├─ Ground (StaticBody3D)
   │  ├─ GroundMesh (MeshInstance3D)
   │  └─ GroundCollider (CollisionShape3D)
   ├─ Player (CharacterBody3D)
   │  ├─ PlayerMesh (MeshInstance3D)
   │  └─ PlayerCollider (CollisionShape3D)
   └─ Sun (DirectionalLight3D)

## 节点属性
```markdown
| node_path | property_name | value |
|-----------|--------------|-------|
| Ground/GroundMesh | mesh | new:BoxMesh |
| Ground/GroundMesh | position | [0, -0.5, 0] |
| Ground/GroundMesh | mesh:size | [20, 1, 20] |
| Ground/GroundCollider | shape | new:BoxShape3D |
| Ground/GroundCollider | shape:size | [20, 1, 20] |
| Player | position | [0, 1, 0] |
| Player/PlayerMesh | mesh | new:CapsuleMesh |
| Player/PlayerCollider | shape | new:CapsuleShape3D |
| Sun | light_energy | 1.5 |
| Sun | shadow_enabled | true |
```
```

---

## 二、Script Editor（脚本编辑）

### 格式规范

任务描述应包含以下部分：

#### 1. 目标文件
指定要编辑的脚本文件路径。

#### 2. 修改说明
根据修改类型，使用不同的描述格式：

##### 类型 A：单处插入/删除
使用 GDScript 代码块标明插入/删除的位置和内容。

```
## 目标文件
res://scripts/player.gd

## 修改说明
在 `_ready()` 函数末尾插入初始化代码：

```gdscript
# 在 _ready() 函数的最后一行之前插入
func _ready():
	# ... 原有代码 ...
	_init_health()    # ← 插入此行
	_setup_input()    # ← 插入此行
```
```

##### 类型 B：多处同时替换（multi_replace）
使用 Markdown 表格描述每一组 `search → content` 替换对，表格用三个反引号 + `markdown` 包裹：

```
## 目标文件
res://scripts/player.gd

## 多处替换
```markdown
| search | content |
|--------|---------|
| old_function_name | new_function_name |
| var speed = 10 | var speed = 20 |
| "health": 100 | "health": 150 |
```
```

### 完整示例

```
## 目标文件
res://scripts/enemy.gd

## 修改说明
1. 重命名 `take_damage` 函数为 `apply_damage`
2. 将伤害值常量从 10 改为 25

## 多处替换
```markdown
| search | content |
|--------|---------|
| func take_damage(amount): | func apply_damage(amount): |
| const DAMAGE = 10 | const DAMAGE = 25 |
```
```

---
