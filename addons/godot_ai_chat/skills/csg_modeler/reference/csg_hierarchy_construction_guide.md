# CSG 层级构造指南

## 概述

CSG 建模的核心在于**通过节点树的结构来表达几何体的组合逻辑**。与传统的网格建模不同，CSG 的"形状"是由节点树的层级关系 + 每个节点的布尔运算类型共同决定的。

> **一句话总结**：CSG 节点树 = 几何组合的"配方"，树的层级结构决定了最终的模型形态。

---

## 一、核心概念：CSG 节点树如何工作

### 1.1 基本规则

```
CSGCombiner3D (operation=0, UNION)
├── CSGBox3D (operation=0, UNION)         ← 主体
├── CSGSphere3D (operation=2, SUBTRACTION) ← 从主体中挖掉球体
└── CSGCylinder3D (operation=0, UNION)     ← 合并到主体上
```

**规则一：父子关系**
- `CSGCombiner3D` 是一个"布尔容器"，它会对其所有**直接子节点**执行布尔运算。
- 子节点之间的运算方式由每个子节点的 `operation` 属性决定。

**规则二：兄弟关系（同一层级）**
- 同一 `CSGCombiner3D` 下的所有直接子节点，按照它们在场景树中的顺序，依次进行布尔组合。
- `operation=0 (UNION)` → 合并形状
- `operation=2 (SUBTRACTION)` → 从已有的组合结果中减去该形状
- `operation=1 (INTERSECTION)` → 只保留该形状与已有结果的重叠部分

**规则三：嵌套（不同层级）**
- 一个 `CSGCombiner3D` 可以包含另一个 `CSGCombiner3D` 作为子节点。
- 内部的 `CSGCombiner3D` 会先对其自己的子节点进行布尔组合，产生一个"子结果"，然后这个"子结果"再参与父级的布尔运算。

### 1.2 嵌套的工作机制

```
CSGCombiner3D (父级, operation=0)
└── CSGCombiner3D (子级, operation=0)
    ├── CSGBox3D (operation=0)
    └── CSGSphere3D (operation=2)
```

**执行顺序**：
1. 先处理子级 `CSGCombiner3D` → 将其内部的 Box 与 Sphere 进行布尔运算，产生一个"中间结果"
2. 再处理父级 → 将这个"中间结果"与父级的其他子节点进行布尔运算

> 💡 嵌套的价值在于：可以对一组形状先进行局部的布尔组合，再将这个组合结果作为一个整体参与更大范围的布尔运算。

---

## 二、层级构造策略

### 2.1 平坦结构 vs 嵌套结构

| 策略 | 适用场景 | 优点 | 缺点 |
|------|---------|------|------|
| **平坦结构** | 简单模型，所有形状在同一层级组合 | 结构简单，容易理解 | 无法实现局部组合后再整体运算 |
| **嵌套结构** | 复杂模型，需要分部件组合再合并 | 可以分部件独立设计，再组装 | 层级深，需要更仔细规划 |

### 2.2 何时使用嵌套

在以下情况，你应该使用嵌套的 `CSGCombiner3D`：

**情况一：部件化建模**
```
// 一个机器人：先分别构建"头部"和"身体"，再组合
CSGCombiner3D "RobotBody" (父组合器)
├── CSGCombiner3D "HeadAssembly" (子组合器-头部)
│   ├── CSGSphere3D "Head" (operation=0)
│   └── CSGSphere3D "LeftEye" (operation=2, SUBTRACTION)
├── CSGCombiner3D "BodyAssembly" (子组合器-身体)
│   ├── CSGBox3D "Torso" (operation=0)
│   └── CSGSphere3D "NeckJoint" (operation=0)
```

**情况二：局部挖空**
```
// 一个内部有腔体的复杂结构
CSGCombiner3D "MainAssembly"
├── CSGCombiner3D "OuterShell" (operation=0)
│   └── CSGBox3D "Shell" (operation=0)
└── CSGCombiner3D "InnerCavity" (operation=2, SUBTRACTION)
    ├── CSGBox3D "Cavity1"
    └── CSGBox3D "Cavity2"
```

### 2.3 节点命名规范

命名节点时，请遵循以下规范：

- **首字母大写**：如 `MainBody`, `LeftArm`, `CutoutHole`
- **语义化名称**：名称应反映节点的功能角色，而非随机字符串
- **层级指示**：可以使用后缀表明节点角色，如 `_Assembly`, `_Part`, `_Cutout`

```
✅ Good: "MainBody", "HandleAssembly", "VentCutout"
❌ Bad:  "Node1", "CSGCombiner3D2", "NewNode"
```

---

## 三、Step-by-Step 构造方法

使用 `edit_scene` 工具构建 CSG 层级时，请遵循以下步骤：

### 3.1 顶层设计阶段

在开始操作之前，先在脑海中或草稿中规划好节点树结构：

```
Root Node (Node3D)
└── CSGCombiner3D "MainAssembly"
    ├── CSGCombiner3D "PartA_Assembly"
    │   ├── CSGBox3D "PartA_Box"
    │   └── CSGCylinder3D "PartA_Cylinder"
    └── CSGCombiner3D "PartB_Assembly"
        ├── CSGSphere3D "PartB_Sphere"
        └── CSGBox3D "PartB_Cutout" (operation=2)
```

### 3.2 自顶向下构建

**第1步：添加根容器**
```
action: "add_node"
parent_path: "."
node_class: "CSGCombiner3D"
node_name: "MainAssembly"
```

> 每次添加后，使用 `get_edited_scene` 确认当前场景树状态。

**第2步：添加子组合器（按部件）**
```
action: "add_node"
parent_path: "MainAssembly"
node_class: "CSGCombiner3D"
node_name: "PartA_Assembly"
```

**第3步：在子组合器中添加基本体**
```
action: "add_node"
parent_path: "MainAssembly/PartA_Assembly"
node_class: "CSGBox3D"
node_name: "PartA_Box"
```

**第4步：重复添加其他基本体**
```
action: "add_node"
parent_path: "MainAssembly/PartA_Assembly"
node_class: "CSGCylinder3D"
node_name: "PartA_Cylinder"
```

**第5步：调整位置和布尔运算**
- 使用 `get_scene_node_properties` 查看节点属性
- 使用 `set_scene_node_properties` 设置 `position` 和 `operation`

### 3.3 完整的构造流程示例

假设要构建一个"带孔洞的盒子+圆柱底座"：

**规划树结构：**
```
Node3D "Root"
└── CSGCombiner3D "MainAssembly"
    └── CSGCombiner3D "BaseWithHole" (父级, operation=0)
        ├── CSGBox3D "Base" (operation=0) ← 主体
        │   └── CSGCylinder3D "Hole" (operation=2) ← 挖孔
        └── CSGCylinder3D "Pillar" (operation=0) ← 底座圆柱
```

**Step 1**: 创建场景（根节点选 `Node3D`）
**Step 2**: 添加 `MainAssembly`（CSGCombiner3D）
**Step 3**: 在 `MainAssembly` 下添加 `BaseWithHole`（CSGCombiner3D）
**Step 4**: 在 `BaseWithHole` 下添加 `Base`（CSGBox3D）
**Step 5**: 在 `Base` 下添加 `Hole`（CSGCylinder3D）← 作为 Base 的子节点！
**Step 6**: 在 `BaseWithHole` 下添加 `Pillar`（CSGCylinder3D）
**Step 7**: 设置 `Hole` 的 `operation=2`（SUBTRACTION）
**Step 8**: 设置 `Hole` 的 `position`，使其穿透 Base
**Step 9**: 设置 `Pillar` 的 `position`，放在底座下方
**Step 10**: 截图检查效果，根据视觉反馈调整

---

## 四、常见建模模式

### 模式一：挖孔/开槽

```
CSGCombiner3D "Part"
├── CSGBox3D "MainBody" (operation=0)
└── CSGCylinder3D "HoleCutter" (operation=2, SUBTRACTION)
```

> **关键**：`HoleCutter` 必须与 `MainBody` 有位置重叠，且它的 `operation` 设为 `2`。
> 位置偏移决定了孔的位置。使用 `set_scene_node_properties` 设置 `position`。

### 模式二：部件组装

```
CSGCombiner3D "Assembly"
├── CSGCombiner3D "LeftSide" (operation=0)
│   ├── CSGBox3D "BoxA"
│   └── CSGSphere3D "KnobA"
├── CSGCombiner3D "RightSide" (operation=0)
│   ├── CSGBox3D "BoxB"
│   └── CSGSphere3D "KnobB"
```

> **关键**：每个子组合器先独立完成自己的组合，然后合并到父级。
> 左半部分和右半部分可以独立定位。

### 模式三：多层嵌套

```
CSGCombiner3D "Outer"
├── CSGCombiner3D "InnerA" (operation=0)
│   ├── CSGBox3D "Core"
│   └── CSGCombiner3D "Cutouts" (operation=2, SUBTRACTION)
│       ├── CSGSphere3D "Hole1"
│       └── CSGSphere3D "Hole2"
└── CSGCylinder3D "Attachment" (operation=0)
```

> **关键**：`Cutouts` 作为一个子组合器，其内部的所有形状会先组合成一个"挖空工具"，然后从 `InnerA` 中减去。

---

## 五、位置与布尔运算的配合

### 5.1 位置决定布尔效果

布尔运算的效果与形状的**空间位置**密切相关。两个形状如果完全没有重叠，UNION 只是把它们放在一起，SUBTRACTION 则不会有任何效果。

**常用定位方式：**

```
// 设置 position 使圆柱穿透盒体
node_path: "MainAssembly/HoleCutter"
property_name: "position"
value: "[0.5, 0, 0]"

// 设置 rotation 使切割体倾斜
node_path: "MainAssembly/HoleCutter"
property_name: "rotation"
value: "[0, 0, 0.785]"  // 45度弧度值
```

> ⚠️ **注意**：`rotation` 使用弧度制。常见换算：45° = 0.785, 90° = 1.57, 180° = 3.14。

### 5.2 位置调整的策略

1. 先添加节点，使用默认位置
2. 截图查看默认效果
3. 根据截图分析，调整 `position`
4. 再次截图确认
5. 迭代直到位置正确

---

## 六、完整示例：构建一个简易桌台

### 目标模型
一个桌面（扁平长方体）+ 四条桌腿（细长圆柱），桌面下方有一个加固横梁。

### 规划树结构

```
Node3D "Root"
└── CSGCombiner3D "TableAssembly"
    ├── CSGBox3D "TableTop" (operation=0)
    │   └── CSGCombiner3D "LegsAssembly" (operation=0)
    │       ├── CSGCylinder3D "Leg1" (operation=0)
    │       ├── CSGCylinder3D "Leg2" (operation=0)
    │       ├── CSGCylinder3D "Leg3" (operation=0)
    │       └── CSGCylinder3D "Leg4" (operation=0)
    └── CSGBox3D "CrossBeam" (operation=0)
```

### 执行步骤

**阶段一：建场景**
```
manage_folder (确认文件夹)
create_scene (root_type="Node3D", 路径="res://models/table.tscn")
open_file (path="res://models/table.tscn")
get_edited_scene (确认空场景)
```

**阶段二：建层级**
```
// 添加主组合器
edit_scene (add_node, parent_path=".", node_class="CSGCombiner3D", node_name="TableAssembly")

// 添加桌面
edit_scene (add_node, parent_path="TableAssembly", node_class="CSGBox3D", node_name="TableTop")

// 添加桌腿组合器（作为桌面的子节点！）
edit_scene (add_node, parent_path="TableAssembly/TableTop", node_class="CSGCombiner3D", node_name="LegsAssembly")

// 添加四条桌腿
edit_scene (add_node, parent_path="TableAssembly/TableTop/LegsAssembly", node_class="CSGCylinder3D", node_name="Leg1")
edit_scene (add_node, parent_path="TableAssembly/TableTop/LegsAssembly", node_class="CSGCylinder3D", node_name="Leg2")
edit_scene (add_node, parent_path="TableAssembly/TableTop/LegsAssembly", node_class="CSGCylinder3D", node_name="Leg3")
edit_scene (add_node, parent_path="TableAssembly/TableTop/LegsAssembly", node_class="CSGCylinder3D", node_name="Leg4")

// 添加横梁（作为 TableAssembly 的直接子节点）
edit_scene (add_node, parent_path="TableAssembly", node_class="CSGBox3D", node_name="CrossBeam")
```

**阶段三：配置属性**
```
// 桌面尺寸
set_scene_node_properties (node_path="TableAssembly/TableTop", property_name="size", value="[2, 0.1, 1]")

// 桌腿位置和尺寸
set_scene_node_properties (node_path="TableAssembly/TableTop/LegsAssembly/Leg1", property_name="radius", value="0.04")
set_scene_node_properties (node_path="TableAssembly/TableTop/LegsAssembly/Leg1", property_name="height", value="0.8")
set_scene_node_properties (node_path="TableAssembly/TableTop/LegsAssembly/Leg1", property_name="position", value="[-0.8, -0.45, -0.35]")

// ... 类似设置其他三条桌腿

// 横梁位置和尺寸
set_scene_node_properties (node_path="TableAssembly/CrossBeam", property_name="size", value="[1.6, 0.05, 0.05]")
set_scene_node_properties (node_path="TableAssembly/CrossBeam", property_name="position", value="[0, -0.4, 0]")
```

**阶段四：视觉检查**
```
set_3d_viewport_camera (position="[3, 2, 3]", look_at="[0, 0, 0]")
capture_edited_scene_screenshot (截图检查)
// 根据截图调整桌腿位置
set_scene_node_properties (...) // 微调
capture_edited_scene_screenshot (再次截图确认)
```

**阶段五：保存**
```
save_edited_file ()
report_task_result (报告完成)
```

---

## 七、常见错误与排查

### 错误一：布尔运算没有效果

**症状**：设置了 SUBTRACTION 但形状没有被减去
**原因**：最常见的原因是位置不对，切割体与被切割体没有重叠
**排查**：截图检查两个形状的位置是否重叠；使用 `get_scene_node_properties` 查看两者的 `position` 和尺寸

### 错误二：模型显示不全或破损

**症状**：部分形状没有显示或显示异常
**原因**：节点顺序问题或 `operation` 设置不正确
**排查**：检查所有 CSG 节点的 `operation` 属性；检查 CSGCombiner3D 本身的 `operation`

### 错误三：形状出现在错误的位置

**症状**：节点在场景树中的位置看起来正确，但实际位置不对
**原因**：子节点的 `position` 是相对于父节点的。如果父节点移动了，所有子节点都会跟着移动
**排查**：使用 `get_scene_node_properties` 逐级检查父子节点的 `position`

### 错误四：嵌套组合器导致意外结果

**症状**：使用嵌套组合器后，模型的形状与预期不符
**原因**：内层组合器的布尔结果与外层组合器的其他节点之间的交互方式可能不是预期的那样
**排查**：简化层级，每次只加一层嵌套并截图确认

---

## 八、黄金法则

1. **先规划，再动手**：在开始操作前，用树状图规划整个 CSG 节点层级
2. **逐级构建，逐级验证**：每添加 2-3 个节点就截图检查一次
3. **减法操作（SUBTRACTION）的节点必须是父级布尔运算的子节点**：要让一个形状从另一个形状中减去，减法节点必须是与被减节点有共同的 CSGCombiner3D 父节点（或作为被减节点的直接子节点）
4. **位置通过 `position` 控制**：永远使用 `set_scene_node_properties` 调整 `position`，禁止直接修改 `scale`
5. **名称即文档**：使用语义化名称，让节点名称反映其功能角色
6. **可视化验证**：每次调整后，使用 `set_3d_viewport_camera` + `capture_edited_scene_screenshot` 获取视觉反馈
