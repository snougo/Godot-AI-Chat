# GDScript 约定：注解准入 与 数据结构建模

> 两部分各自独立。§1 决定「加不加注解」，§2 决定「用什么数据形状」。

## §1 注解准入：`@tool` 与 `class_name`

> **默认都不加**，只在跨边界时加。互不替代，不传染（父类加了子类仍需自己写）。

### `@tool` 的实际作用

`@tool` 是脚本自身的标志位（`GDScript::tool`），影响三处：

| 作用点 | 具体行为 |
|---|---|
| 场景实例 | 编辑器中把**非 tool 脚本**挂到 Node 上 → 得到 `PlaceHolderScriptInstance` 占位实例：`_ready` / `_process` 不执行，导出属性走 fallback |
| `can_instantiate()` | `valid && !_is_abstract && (tool \|\| ScriptServer::is_scripting_enabled())`；编辑器内 `scripting` 为 true，故非 tool 类通常也返回 true |
| `reload()` 的 `can_run` | 同上式，决定是否执行 `_static_init()`（静态变量初始化） |

**关键**：`GDScript.new()` 走 `_new()`，只检查 `valid` 与 `_is_abstract`，**不看 `tool`**。所以「编辑器里 `new()` 一个非 tool 的 `RefCounted` 类」是合法的，可正常调用方法。

### 判定标准（一句话）

> **看这个类在编辑器里以什么形式存在**：作为 Node / Resource 存在 → 加；只作为 `RefCounted` 被 `new()` 出来 → 不加。

| 情形 | `@tool` | 漏加的后果 |
|---|---|---|
| 挂在 `.tscn` 节点上，编辑期需真实执行 | ✅ | 退化为占位实例，方法静默不执行、不报错 |
| `.tres` / `.res` 资源脚本 | ✅ | Inspector 中只有占位属性，脚本逻辑不生效 |
| `EditorPlugin` / `EditorScript` | ✅ | 引擎显式要求，直接不工作 |
| 编辑器代码会 `new()` **节点类**并调用 | ✅ | 同第一行 |
| `RefCounted` 工具类，仅 `new()` 后调方法（含被 `WorkerThreadPool` 工作线程调用） | ❌ | 无影响（4.8 实测可正常实例化与调用） |
| 仅含 `static func` / `const` / `enum` | ❌ | 静态调用不创建实例 |

### 常见误区

- ❌「编辑器无法实例化非 tool 脚本」——这是**早期 4.x** 的行为（判定为 `is_editor_hint() && !is_tool()`）。现代版本已放宽为 `tool || ScriptServer::is_scripting_enabled()`。官方文档相关表述偏旧，且主要描述的是**节点占位实例**，不要套用到 `RefCounted` 工具类。
- ❌「父类是 `@tool`，子类就不用写」——标志位不继承，子类必须自己声明。
- ✅ 判断依据是「存在形式」，不是「是否在编辑器里被调用」。

### `class_name`

只有下面 3 种情形必须加：

| 必须加 | 说明 |
|---|---|
| 文件内引用**自身类名**（`-> 自身类名`、`自身类名.new()`、`var x: 自身类名`） | 同文件 `preload` 自己会成环，且 GDScript 没有 `Self` 之类的自身类型代称，**无替代写法** |
| 需出现在「新建节点 / 新建资源」对话框 | 由编辑器类表驱动（仅 `Node` / `Resource` 子类会出现） |
| 需被 `.tres` 按 `script_class` 识别 | 序列化依赖全局类名 |

**不加**：只经 `new()` 创建的类、纯静态类。此时用 `const Foo = preload("res://...")` 顶替，消费方写 `const Foo := preload(...)` 后用法与全局类名几乎一致（见下节），且不占用全局类名。

**自查方法**：想给某类删 `class_name` 时，先在该类**自己的文件内** grep 类名 —— 命中即必须保留（`markdown_palette.gd` 的 `static func from_base() -> MarkdownPalette` 就是这种情况）。

### `preload` 常量的能力边界

`const Foo = preload("res://...")` 之后，`Foo` 可当类型名使用，覆盖绝大多数跨文件引用场景：

| 用法 | 是否可用 | 备注 |
|---|---|---|
| `var x: Foo` / `-> Foo` / 参数 `p: Foo` | ✅ | 基础用法 |
| `x is Foo` / `Foo.new()` | ✅ | |
| `var t: Foo.Inner` / `Array[Foo.Inner]` / `-> Foo.Inner` / 参数 `p: Foo.Inner` | ✅ | **4.8 beta1 实测**：内部类作类型位置全部通过 |
| 外层类作泛型参数：`Array[Foo]` / `Dictionary[String, Foo]` | ✅ | **4.8 beta1 实测**：泛型元素类型 / 值类型均通过 |
| `Foo.SOME_CONST` / `Foo.SomeEnum.VALUE` | ✅ | 常量与枚举访问 |
| 文件内对自身类名的引用 | ❌ | 同文件 `preload` 自己会成环 —— 这是**唯一**替代不了的情形 |

> **历史更正**：本文档早期版本曾把「`Array[X]` / `Dictionary[.., X]` 元素类型」与「`X.InnerClass` 类型位置」列为 `preload` 替代不了的情形。该结论基于早期 4.x 经验，**在 4.8 beta1 上均已不成立**：
> - `const GDScriptTokenizer := preload(...)` 后 `GDScriptTokenizer.Token` 作变量标注 / 泛型元素 / 返回类型 / 参数类型全部编译通过（`run_editor_script_tool.gd` 中 4 处即此用法，端到端实测通过）
> - `Array[ProbeSeg]`、`Dictionary[String, ProbeSeg]`、`-> ProbeSeg`、`ProbeSeg.Kind`、`x is ProbeSeg` 全部通过（`markdown_segment.gd` 删名后 19 处泛型用法实际运行于流式渲染链路）

**多消费方时的权衡**：删 `class_name` 后，每个消费方都要各自写一行 `const ... = preload(...)`。消费方只有 1~2 个时划算；若将来消费方增多，把 `class_name` 加回来更省事。

**命名**：新类加插件前缀（`MyPluginXxx`），避开 `Manager` / `Controller` / `Config` / `Utils`。

**验证**：改动 `@tool` 或 `class_name` 后，必须**停用插件或重启编辑器**再验证。原因：插件 `new()` 出来并缓存在字典里的实例不会随脚本重载自动替换；`class_name` 改名/移动后还需排查 `$Node` / `%Node` / 字符串字面量，以及 `.godot/global_script_class_cache.cfg` 里的路径缓存。

## §2 数据结构建模

> 字段名在写代码时已确定（**记录**）→ 用类型化类；键名由数据决定（**映射**）→ 用 Dictionary。
> 记录用 Dictionary = 字段名 / 存在性 / 类型三项检查全外包给运气。`Dictionary[K, V]` 只约束类型、不约束键集合，**不能替代记录**。

**记录类模板**（`Resource` 数据类按 §1 补 `@tool` + `class_name`）

```gdscript
extends RefCounted

var mode: int
var indices: PackedInt32Array

func _init(p_mode: int, p_indices: PackedInt32Array) -> void:
	mode = p_mode
	indices = p_indices
```

1. `_init` 参数**不给默认值**（否则允许无参 `new()`，忘传字段不报错）。
2. **不写 static 工厂**（纯搬运无意义），直接 `new(a, b)`。
3. 纯数据类**不放行为**（`is_empty` / `to_dict` 放调用方）。
4. 空只用一个表达：用了 `null` 就别再有 `is_empty()`。
5. `core/` 数据类不引用上层节点类；上层语义用 `int` 承载。

**必须用 Dictionary 时**

- 键名提为 `const KEY_XXX: String = "xxx"`，定义在生产方；全链路统一 `String` 或 `StringName`，**不混用**（否则「键存在却取不到」）。
- **记录取字段禁用 `.get(key, default)`** —— 缺字段是 bug，必须炸出来；`.get()` 只用于映射中确实可选的配置项。

**改名：变量名 ≠ 字符串键**，必须单独排查 `{"key": ...}`、`dict["key"]`、`dict.get("key")`、常量 / 枚举、测试断言、注释。
> 事故：键 `"mode"` 未同步为 `"select_mode"` → 取到 `null` → `int(null)` = `0` → 静默跳错模式，无报错。

收尾：`grep` 旧名字 0 命中；对该结构 `grep 'get("'` 0 命中。

**反模式**

| 反模式 | 改法 |
|--------|------|
| `return {"mode": m}` 跨函数传记录 | 返回记录类实例 |
| `d.get("key", -1) == X` 断言 | `d.key == X`（拼错即编译错） |
| 无参 `new()` + 逐个赋值 | `_init` 带无默认参数 |
| 裸字符串键散落多处 | 提 `String` 常量 |
