# 场景节点参数指南

## node_path — 节点路径

用于定位场景中的目标节点，支持以下三种格式：

| 格式 | 示例 | 说明 |
|------|------|------|
| `.` | `"."` | 场景根节点 |
| `NodeName` | `"Player"` | 节点名称（仅在场景内唯一时可用） |
| `Parent/Child` | `"Player/Body/Sprite"` | **推荐** — 从根节点起的相对路径 |

> 💡 使用 `get_edited_scene` 工具先查看当前场景结构，可获取所有可用路径。

---

## property_name — 属性名（仅 `set_scene_node_properties` 使用）

支持两种寻址方式，**用冒号 `:` 区分层级**（切勿混用斜杠 `/`）：

### 1. 简单属性（直接位于节点上）
直接写属性名即可：

```
"position"
"scale"
"visible"
```

### 2. 嵌套资源属性（节点 → 资源 → 子属性）
使用 **冒号 `:`** 分隔层级：

```
节点名:资源属性:子属性
```

**示例：**

| 写法 | 含义 |
|------|------|
| `TestCapsule:mesh:height` | 设置 CapsuleMesh 的 height |
| `TestCapsule:mesh:material:albedo_color` | 设置材质的 albedo_color（三级嵌套） |

> ❌ **错误用法**：`TestCapsule/mesh/height`（用斜杠访问资源属性）
> ✅ **正确用法**：`TestCapsule:mesh:height`（用冒号访问资源属性）

---

## value — 属性值（仅 `set_scene_node_properties` 使用）

支持以下格式，系统会自动进行类型转换与验证：

| 类型 | 输入格式 | 示例 |
|------|----------|------|
| **Bool** | `"true"` / `"false"` | `"true"` |
| **Number** | 数字字符串 | `"100"`, `"3.14"` |
| **Vector2** | `"[x, y]"` | `"[10, 20]"` |
| **Vector3** | `"[x, y, z]"` | `"[1, 2, 3]"` |
| **Color (RGB)** | `"[r, g, b]"` | `"[1, 0, 0]"` |
| **Color (RGBA)** | `"[r, g, b, a]"` | `"[1, 0, 0, 0.5]"` |
| **Color (Hex)** | `"#RRGGBB"` | `"#ff0000"` |
| **String** | 普通字符串 | `"hello"` |
| **Resource (加载)** | `"res://路径"` | `"res://assets/my_material.tres"` |
| **Resource (新建)** | `"new:ClassName"` | `"new:StandardMaterial3D"` |
| **置空** | `"null"` | `"null"` |

---

## 快速参考

| 场景 | 写法 |
|------|------|
| 获取根节点属性 | `node_path="."` |
| 获取子节点属性 | `node_path="Player/Body"` |
| 设置简单属性 | `property_name="position"` + `value="[0, 5, 0]"` |
| 设置资源嵌套属性 | `property_name="TestCapsule:mesh:height"` + `value="2.5"` |
| 设置材质颜色 | `property_name="MyMesh:material:albedo_color"` + `value="[1, 0, 0]"` |
