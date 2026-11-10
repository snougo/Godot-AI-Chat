# 场景节点参数指南

适用于 `get_scene_node_properties` / `set_scene_node_properties`（`create_scene` 的 `properties` 字段用同一套规则）。

---

## 1 `node_path` — 节点路径

| 写法 | 示例 | 说明 |
|---|---|---|
| 根 | `"."` | 场景根节点 |
| 相对 | `"Player/Body/Sprite"` | **推荐**，从根节点往下 |
| 绝对 | `"/Player/Body"` 或 `"/RootName/Player/Body"` | 工具会自己剥掉根名——不要指望 Godot 的绝对路径（编辑场景不在 `/root` 下） |
| 裸名字 | `"Player"` | **仅当场景内唯一**时才解析；有同名时直接报错并列出全部候选 |

> 路径写错时，错误里会附上"当前场景所有可用路径 + 相似建议"，照着换一个即可。

---

## 2 读属性

```jsonc
{"node_path": "Player/Body", "include_raw": false, "include_resources": false}
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `include_raw` | `false` | 额外给出 JSON 安全的值（Vector3 → `[x,y,z]`，Color → `#RRGGBBAA`） |
| `include_resources` | `false` | 额外列出所挂资源自身的可编辑属性（例如 `shape` 的 `radius`） |

默认只回 `{"value": "<字符串>", "type": "<类型>"}`：省 token，也避免 `raw` 与 `value` 在 JSON 里退化成两份几乎一样的文本。

---

## 3 写属性：`property` + `sub_path`

### 3.1 节点自身属性

```jsonc
{"node_path": "Player/Body", "property": "position", "value": "[0, 1, 0]"}
{"node_path": "HUD/Score", "property": "visible", "value": "false"}
```

### 3.2 资源上的子属性：用 `sub_path` 数组

```jsonc
{"node_path": "Player/Body", "property": "shape",
 "sub_path": ["radius"], "value": "0.6"}

{"node_path": "Mesh", "property": "mesh",
 "sub_path": ["material", "albedo_color"], "value": "#3388ff"}
```

> 旧写法 `"property": "mesh:material:albedo_color"` 仍被接受（兼容用）。
> 但**不要**把节点名写进 `property`：`"TestCapsule:mesh:height"` 会被当成"节点上没有名为 TestCapsule 的属性"而报错。

### 3.3 两个特殊属性

| 属性 | 行为 |
|---|---|
| `name` | 自动转交给 `rename_scene_node`（要做重名/非法字符校验、要回新路径） |
| `owner` | **拒绝**。写坏了是场景归属损坏，用 add / delete / move 工具 |

`scale` 现在**可以正常设置**（旧版误列进了黑名单）。

---

## 4 `value` 的格式

优先传**原生 JSON 类型**（数组 / 数字 / 布尔 / 对象）；很多 provider 只允许字符串，所以下面的字符串写法一律等价可用。

| 目标类型 | 原生写法 | 字符串写法 |
|---|---|---|
| bool | `true` / `false` | `"true"` / `"false"` / `"1"` / `"0"` / `"yes"` / `"no"` |
| int | `3` | `"3"` / `"3.0"` |
| float | `3.5` | `"3.5"` |
| String | `"hello"` | `"hello"` |
| Vector2 | `[10, 20]` | `"[10, 20]"` / `"10, 20"` / `"(10, 20)"` |
| Vector3 | `[1, 2, 3]` | `"[1, 2, 3]"` / `"1, 2, 3"` |
| Vector2i / Vector3i | `[1, 2]` | 同上（四舍五入） |
| Color | `[0.2, 0.5, 1.0]` | `"#3388ff"` / `"#3388ffcc"` / `"Color(0.2, 0.5, 1.0, 1)"` |
| Resource | `"res://materials/stone.tres"` | 同左 |
| 新建资源 | `"new:SphereShape3D"` | 同左 |
| 清空引用 | `"null"` | `"null"` |
| Array / Dictionary | `[1, 2]` / `{"a": 1}` | `"[1, 2]"` / `"{\"a\": 1}"`（JSON 文本） |
| Transform3D / Basis / AABB / Rect2 等 | — | 只能传引擎写法，如 `"Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 1, 0)"` |

**Color 的 0–255 规则**：任一通道的绝对值大于 1 时，整体按 0–255 解释（`[255, 0, 0]` → 正红）。
旧版会把 `[255, 0, 0]` 静默 clamp 成白色，现在不会了。

---

## 5 回执怎么读

```jsonc
{
  "ok": true,
  "op": "set",
  "scene": "res://scenes/Player.tscn",
  "node_path": "Player/Body",
  "property": "shape:radius",
  "type": "float",
  "old_value": 0.4,
  "new_value": 0.6,
  "applied": true,
  "saved": false,
  "unsaved": true
}
```

- `new_value` 是**写完读回来的实际值**（不是"想写的值"）。
- `applied: false` 说明属性接受了赋值但读回不同（被 clamp / 被 setter 改写）——这时以 `new_value` 为准。
- `unsaved: true` = 只在编辑器内存里，需要 `save_edited_file(file_type="scene")`。

---

## 6 常见失败与对策

| 错误 | 对策 |
|---|---|
| `Property 'x' not found on Node. Candidates: ...` | 从候选里选；读属性时用 `include_resources: true` 看资源内部字段 |
| `'shape' is null on Body, so 'shape:radius' cannot be set.` | 先给 `shape` 赋值（如 `"new:SphereShape3D"`），再改子属性 |
| `Sub-path 'material:albedo_color' not found under 'mesh'.` | 子路径写错，或该资源没有这个属性 |
| `Cannot set 'radius' (float): '<文字>' is not a number.` | 值格式不对，按第 4 节改 |
| `Property type Transform3D must be passed as text` | 用 `"Transform3D(...)"` 形式的字符串 |
| `Setting 'owner' corrupts scene ownership` | 用 add / delete / move 工具 |
| `Unknown parameter(s): property_name` | 新工具用 `property`；旧名只是兼容，别混用 |
