# capture_scene_ascii_map 工具使用指南

## 用途

将当前编辑场景的 3D 节点渲染为**字符平面图**（ASCII Map）。

与截图不同：字符地图的**每个格子都与场景树节点一一对应**（字母 ID），
并附带图例（节点路径、类型、尺寸、高度/深度范围）。
这解决了"截图画面与场景树割裂"的问题——你可以直接通过文本阅读
场景的空间布局，并据此定位需要修改的节点。

## 适用场景

- 检查场景整体布局（物体相对位置、是否重叠、间距是否合理）
- 检查俯视/侧视下的遮挡关系（如墙体是否挡住角色）
- 搭建前规划空间（先看地图，再决定在何处添加节点）
- 验证修改结果（修改后再次调用，对比前后地图）

## 参数

| 参数 | 类型 | 默认 | 说明 |
|------|------|------|------|
| `view` | string | `"top"` | `"top"` 俯视（XZ 平面）；`"side_z"` 从 +Z 看（XY 平面）；`"side_x"` 从 +X 看（ZY 平面） |
| `width` | int | `40` | 网格列数（每行字符数），范围 16-200 |
| `height` | int | `24` | 网格行数（字符行数），范围 8-200 |
| `mode` | string | `"node"` | `"node"` 每格显示节点 ID；`"depth"` 每格显示深度亮度 |
| `show_legend` | bool | `true` | 是否输出图例（depth 模式下忽略） |

## 输出解读

### 示例（俯视图 40x24）

```
=== Scene ASCII Map [Top View (XZ plane)] 40x24 ===
World bounds: pos=(0.00, 0.00) size=(16.00, 10.00) | cell=0.40 x 0.42 (m)
+----------------------------------------+
|........................................|
|..AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA...|
|..AAAAAAAAAAAABBBBBBBBBBBBBBAAAAAAAA...|
|..AAAAAAAAAAAABBBBBBBCCCCBBBBAAAAAAAA...|
+----------------------------------------+
Each letter = a node (see Legend). '.' = empty cell.
Occlusion: top = taller wins; side = nearer wins; flat ground pads the bottom.

Legend (ID -> node):
  A -> Ground (MeshInstance3D) | /root/Main/Ground | size 16.00x0.10x10.00 | y [0.00 ~ 0.10]
  B -> Wall_01 (StaticBody3D) | /root/Main/Walls/Wall_01 | size 0.50x4.00x0.50 | y [0.00 ~ 4.00]
  C -> Player (CharacterBody3D) | /root/Main/Player | size 0.50x1.80x0.50 | y [0.00 ~ 1.80]

Occluded (exists but hidden in this view): D:Enemy
```

### 关键概念

- **字母 ID → 节点**：网格中的字母（A-Z, a-z, AA...）由图例映射到具体节点。
- **空地块** `'.'`：该位置没有节点投影。
- **遮挡规则**：
  - 俯视图：**越高越优先**显示（高物体盖住低物体，如墙盖住墙后地面）
  - 侧视图：**越近越优先**显示；薄水平平面（地面类）自动垫底
- **图例字段**：`ID -> 节点名 (类型) | 完整路径 | 尺寸 WxHxD | 深度轴范围`
  - 俯视图深度轴 = `y`（高度范围，如墙 y [0 ~ 4] 表示 0-4 米高）
  - 侧视图深度轴 = `z` 或 `x`（前后范围）
- **Occluded 列表**：场景中存在但在当前视图被完全遮挡的节点——修改它们时需切换到其他视图或调整视角。

### depth 模式

`mode: "depth"` 时网格显示深度亮度而非节点 ID：

- 俯视图：亮度 = 该位置的高度（越高越亮）→ 可直观看出地形起伏/物体高低
- 侧视图：亮度 = 与观察者的距离（越近越亮）→ 可看出前后层次

## 使用建议

1. **先 top 后 side**：先用俯视图看平面布局，再用侧视图看高度/前后关系。
2. **发现被遮挡节点**：若 Occluded 列表有重要节点（如角色），说明它藏在物体后，
   可用 `side_z`/`side_x` 或配合 `set_3d_viewport_camera` 调整视角复查。
3. **修改后复查**：每次修改场景布局后重新调用，对比地图变化。
4. **大场景分段查看**：场景过大时节点密集，可适当增大 width/height，或先聚焦局部。
5. **与截图配合**：字符地图用于定位节点（文本、可指认），截图用于观感检查（材质、光照），两者互补。
