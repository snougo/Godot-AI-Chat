# apply_scene_edits 使用指南

> 适用于 `apply_scene_edits`：场景结构改动（增 / 删 / 移动 / 改名）与属性设置。
> 属性取值格式见 `scene_node_params_guide.md`；新建 `.tscn` 用 `create_scene`；只想改一个属性时也可以直接用 `set_scene_node_properties`。

---

## 1 调用形态

```jsonc
{
  "ops": [
    {"op": "add", "parent_path": "Player", "node_type": "CollisionShape2D", "node_name": "Hitbox"},
    {"op": "set", "node_path": "Player/Hitbox", "property": "shape", "value": "new:CircleShape2D"}
  ],
  "stop_on_error": true,
  "rollback_on_error": true,
  "save": false,
  "verbose": false
}
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `ops` | 必填 | 非空数组，**按顺序**执行 |
| `stop_on_error` | `true` | 遇到第一条失败就停 |
| `rollback_on_error` | `true` | 失败时把已成功的几条撤销掉 |
| `save` | `false` | **全部成功**才写盘 |
| `verbose` | `false` | 回执附整棵场景树 |

只改一处就在 `ops` 里放一条，不需要别的工具。

---

## 2 五种 op

| `op` | 必填字段 | 可选字段 | 示例 |
|---|---|---|---|
| `add` | `parent_path` + （`node_type` 或 `scene_path`） | `node_name` | `{"op":"add","parent_path":".","node_type":"Sprite2D","node_name":"Icon"}` |
| `delete` | `node_path` | — | `{"op":"delete","node_path":"Enemies/Goblin"}` |
| `move` | `node_path` + `parent_path` | — | `{"op":"move","node_path":"HUD/Score","parent_path":"HUD/TopBar"}` |
| `rename` | `node_path` + `new_name` | — | `{"op":"rename","node_path":"Player/Body","new_name":"Mesh"}` |
| `set` | `node_path` + `property` + `value` | `sub_path` | `{"op":"set","node_path":"Icon","property":"position","value":"[0,-16]"}` |

- `add` 的 `node_type` 与 `scene_path` **二选一**，同时给会报错。
- `set` 的 `property` 为 `name` 时等同于改名；为 `owner` 时直接拒绝。
- `op` 名**区分大小写**，写 `"Add"` 会得到 `unknown op`。

---

## 3 顶层参数不要塞进 op

`save` / `verbose` / `stop_on_error` / `rollback_on_error` 只属于顶层。写进 `add` / `delete` / `move` / `rename` 的 op 里会报：

```
Unknown parameter(s): save. Allowed here: parent_path, node_type, scene_path, node_name.
```

> `set` 的 op 目前仍会接受 `save` / `verbose`（但不起作用）——不要依赖这一点，落盘请用顶层 `save`。

---

## 4 顺序与路径依赖

后一条 op 可以引用前面 op 刚创建的节点，但路径必须是**真实最终路径**：

```jsonc
{"ops": [
  {"op": "add", "parent_path": ".", "node_type": "Node2D", "node_name": "Enemies"},
  {"op": "add", "parent_path": "Enemies", "node_type": "Sprite2D", "node_name": "Goblin"},
  {"op": "set", "node_path": "Enemies/Goblin", "property": "position", "value": "[32,0]"}
]}
```

- 场景根写 `"."`；其余写 `Parent/Child`（相对路径），裸名字只在场景内**唯一**时可用。
- `add` 没给 `node_name` 且与兄弟重名时，会**自动加序号**（`Sprite2D2`）并回 `renamed: true`——后续 op 若仍按旧名字写就会失败。要么显式给名字，要么按回执里的新名字继续。
- `rename` 之后的 op 必须用新名字（回执里有 `node_path_before` 与 `node_path`）。
- 路径没把握时：先 `get_edited_scene` 看一眼，或者先提交一次只含 `add` 的调用，用回执里的 `node_path` 再发下一批。

---

## 5 失败与回滚

- 每条成功的 op = 编辑器撤销栈里的一个独立步骤。
- 失败且 `rollback_on_error: true` 时，会按**已成功条数**连续撤销，效果相当于在编辑器里按了几次 Ctrl+Z。
- `rollback_on_error: false` 时，已成功的改动**保留**，只有失败那条及之后（若 `stop_on_error`）没做。
- `failed_index` 为 `-1` 表示全部成功。

---

## 6 回执怎么读

成功：

```jsonc
{
  "ok": true, "op": "batch", "scene": "res://scenes/Level01.tscn",
  "ops_total": 3, "applied": 3, "failed_index": -1, "rolled_back": false,
  "results": [
    {"ok": true, "op": "add", "node_path": "Player/Hitbox", "class": "CollisionShape2D",
     "instance_of": "", "name": "Hitbox", "renamed": false, "index": 0},
    {"ok": true, "op": "set", "node_path": "Player/Hitbox", "property": "shape",
     "type": "Resource/Object", "old_value": null, "new_value": "<CircleShape2D>",
     "applied": true, "index": 1}
  ],
  "saved": true, "unsaved": false
}
```

失败（`stop_on_error` 默认值下，`results` 只到失败那条为止）：

```jsonc
{
  "ok": false, "op": "batch", "scene": "res://scenes/Level01.tscn",
  "ops_total": 3, "applied": 1, "failed_index": 1, "rolled_back": true,
  "results": [
    {"ok": true, "op": "add", "node_path": "Player/Hitbox", "index": 0, "...": "..."},
    {"ok": false, "op": "set", "error": "Property 'shap' not found on Hitbox. Candidates: shape", "index": 1}
  ]
}
```

- `applied` / `failed_index` / `rolled_back` 是判断"环境现在处于什么状态"的三个关键字段：`rolled_back: true` 表示场景已回到调用前，改完参数可以整体重发。
- 失败时**不会**写盘（`save` 只在全部成功时生效）。
- `set` 的 `applied: false` 表示写入被接受但读回不同（被 clamp / 被 setter 改写），以 `new_value` 为准。

---

## 7 常见失败与对策

| 回执 | 原因 / 对策 |
|---|---|
| `No active scene in the editor.` | 先用 `open_file` 打开目标场景 |
| `'ops' must be a non-empty array of operation objects.` | `ops` 缺失、不是数组或为空 |
| `each op must be an object with an "op" field` | 某条 op 不是对象（常见：多套了层数组） |
| `unknown op 'Add' (supported: add, delete, move, rename, set)` | `op` 值拼错或大小写不对 |
| `Unknown parameter(s): save. Allowed here: ...` | 顶层参数写进了 op 里 |
| `'parent_path' is required. Use "." for the scene root.` | `add` 没给父节点 |
| `'X' is not an instantiable Node class. Candidates: ...` | 类名拼错，或不是 Node 子类 |
| `'...' already has a child named 'Crate'. Pick another name — 'Crate2' is free.` | 显式给了重名；按建议改名，或去掉 `node_name` 让它自动编号 |
| `Ambiguous node name 'Label': 3 nodes share it...` | 裸名字不唯一，改写成完整路径 |
| `'...' is an internal node of the instanced scene 'res://...'` | 想改外部实例内部节点：打开那个子场景再改 |
| `The scene root cannot be deleted.` / `The scene root cannot be moved.` | 根节点只能改名或改属性 |
| `Cannot move 'A' into its own descendant.` | 换父节点会成环 |
| `'Crate:Size' is not a valid node name — Godot would store it as 'Crate_Size'.` | 名字含非法字符，按给的写法改 |
| `save_scene() failed (error ...)` 出现在 `save_error` | 场景从未保存过，先在编辑器里存一次 |

---

## 8 用这个工具做不到的事

| 需求 | 用什么 |
|---|---|
| 新建一个 `.tscn` 文件 | `create_scene` |
| 编辑外部实例（带 `scene_file_path` 的祖先）内部的节点 | 先 `open_file` 打开那个子场景 |
| 删掉 / 移动场景根 | 不支持；根节点只能改名、改属性 |
| 直接写 `owner` | 不支持，会损坏场景归属 |
| 一次改多个属性 | 拆成多条 `set` op，路径相同即可 |
| 把改动写到磁盘 | 顶层 `"save": true`，或 `save_edited_file(file_type="scene")` |
