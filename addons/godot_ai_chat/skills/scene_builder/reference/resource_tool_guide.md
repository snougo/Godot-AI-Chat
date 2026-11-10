# 资源工具指南（create_resource / edit_resource / get_resource_properties）

> 三个工具处理 `.tres` / `.res`。与场景工具的区别只有一点：**资源是立即写盘的**，没有"编辑器里未保存"的状态，
> 所以也没有 `save` 参数；代价是**没有 UndoRedo**，回退靠 `rollback_files` / git。

---

## 1 工具一览

| 工具 | 作用 | 必填 |
|---|---|---|
| `create_resource` | 新建资源（可一次带初始属性） | `path`（文件夹）、`file_name`、`resource_type` |
| `edit_resource` | 改已有资源的属性（全成功或全不写） | `path`、`properties` |
| `get_resource_properties` | 列出可编辑属性与当前值 | `path` |

`path` 规则：`res://` 开头、文件已存在（create 时要求**文件夹**已存在）、扩展名 `.tres` / `.res`。

---

## 2 `create_resource`

```jsonc
{"path": "res://materials/", "file_name": "stone.tres",
 "resource_type": "StandardMaterial3D",
 "properties": {"albedo_color": "#8a7f70", "roughness": 0.85}}
```

- `file_name` 只能是**纯文件名**（目录写在 `path` 里，写进 `file_name` 会报错）。
- `resource_type` 必须是**可实例化的具体类型**：
  - 引擎类：`StandardMaterial3D`、`StyleBoxFlat`、`Gradient`、`Curve`…
  - 项目里的脚本资源 `class_name` 也支持（`ClassDB` 里没有脚本类，工具会去 `ProjectSettings.get_global_class_list()` 找）。
- `Resource` / `RefCounted` / `Object` 这类基类**直接被拒**：存出来的文件里没有任何内容。
- 类型名写错时会给出相近候选（`Candidates: ...`）。
- 已存在的文件不会被覆盖。
- `properties` 里的写法与 `edit_resource` 完全一致（见第 4 节）；**任意一条不合法就整份不创建**。

---

## 3 `edit_resource`

```jsonc
{"path": "res://materials/stone.tres",
 "properties": {
   "albedo_color": "#8a7f70",
   "roughness": 0.85,
   "metallic": 0.0,
   "albedo_texture": "res://textures/stone_albedo.png"
 }}
```

- `properties` 是一个对象：键是属性名，值是新值。
- **全成功或全不写**：先把每一条都解析校验，只要有一条不合法就整份拒绝（不会出现"改了一半"）。
- 写盘失败时会把内存里已改的值**改回去**，文件保持原样，并在回执里说明。
- 回执逐条给 `old_value` / `new_value` / `applied`：
  `applied: false` 表示赋值被引擎接受但读回不同（被 clamp、被 setter 改写），以 `new_value` 为准；
  `mismatched` 是这类条目的总数。

---

## 4 属性键与值

### 4.1 键：`property` 或 `property:sub_property`

| 写法 | 含义 |
|---|---|
| `"roughness"` | 资源自身的属性 |
| `"mesh:height"` | 资源的 `mesh` 子资源的 `height` |
| `"mesh:material:albedo_color"` | 三级：`mesh` → `material` → `albedo_color` |
| `"mesh/height"` | ❌ 报错并提示改用 `:`（斜杠是节点路径，不是属性路径） |

### 4.2 值：原生类型与字符串都行

| 目标类型 | 原生写法 | 字符串写法 |
|---|---|---|
| bool | `true` | `"true"` / `"0"` / `"no"` |
| int / float | `3` / `0.85` | `"3"` / `"0.85"` |
| String | `"stone"` | 同左 |
| Vector2 / Vector3 | `[1, 2]` / `[1, 2, 3]` | `"[1, 2, 3]"` / `"Vector3(1, 2, 3)"` |
| Color | `[0.54, 0.5, 0.44]` | `"#8a7f70"` / `"Color(0.54, 0.5, 0.44, 1)"` |
| 贴图/材质等引用 | `"res://textures/x.png"` | 同左 |
| 新建子资源 | `"new:StandardMaterial3D"` | 同左 |
| 清空引用 | `"null"` | `"null"` |
| Array / Dictionary | `[1, 2]` / `{"a": 1}` | JSON 文本 |
| Transform3D / Basis / AABB 等 | — | 引擎写法，如 `"Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)"` |

**Color 的 0–255 规则**：任一通道绝对值 > 1 时整体按 0–255 解释（`[255, 0, 0]` → 正红）。
旧版本会把 `[255, 0, 0]` 静默 clamp 成白色。

**`"null"` 现在真的能清空引用了**（旧版会把它当字符串塞进 Object 属性，报成功但实际没生效）。

---

## 5 `get_resource_properties`

```jsonc
{"path": "res://materials/stone.tres", "include_raw": false, "include_sub_resources": false}
```

| 字段 | 默认 | 说明 |
|---|---|---|
| `include_raw` | `false` | 额外给出 JSON 安全值（Vector3 → `[x,y,z]`，Color → `#RRGGBBAA`） |
| `include_sub_resources` | `false` | 额外列出所挂子资源自身的可编辑属性 |

默认输出 `{path, type, script, properties: {名字: {value, type}}}`，JSON 格式，不会像旧版那样把长值截断成 `...`。

---

## 6 常见错误对照

| 回执 | 原因 |
|---|---|
| `'Resource' is a base type — a file created from it would be empty.` | `resource_type` 用了基类 |
| `'StandardMaterial' is not an instantiable Resource class. Candidates: StandardMaterial3D, ...` | 类型名拼错/不可实例化 |
| `'file_name' must be a bare file name — put the directory in 'path'.` | 把目录写进了 `file_name` |
| `Nothing was written — 2 of 3 properties are invalid:` + 明细 | 有一条不合法，整份没写 |
| `Property 'roughnesss' not found on StandardMaterial3D. Candidates: roughness, ...` | 属性名拼错 |
| `'mesh' is null on ... , so 'mesh:height' cannot be set.` | 子资源还没赋值，先给 `mesh` 一个值 |
| `use ':' for sub-properties ... not '/'` | 键里用了斜杠 |
| `ResourceSaver.save() failed (error ...)` | 路径不可写/文件夹不存在/被占用 |
