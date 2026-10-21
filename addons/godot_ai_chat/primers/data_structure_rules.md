# 数据结构与「记录」建模规范

> **用途**：避免用 `Dictionary[String, Variant]` 传递**结构化记录**所导致的静默错误（键名漂移、缺键降级、字段类型失控）。适用于本项目全部 GDScript 代码。
> **配套**：命名 / 类型 / 布局规范见 `gdscript_code_style.md`；本节只谈**数据形状**的选型。

---

## 一、先分类：这个 Dictionary 是「记录」还是「映射」

| 形态 | 键集合 | 典型用途 | 结论 |
|------|--------|----------|------|
| **映射（map）** | 开放、运行时决定（如 `String → Node` 注册表、`Vector2i → 数据`） | 查找表、缓存、索引 | ✅ 用 Dictionary |
| **记录（record）** | 编译期已知且固定（如 `{mode, indices}`、`{vertex_count, vertex_tail, faces}`） | 跨函数传递一条结构化数据 | ❌ 禁用 Dictionary，用类型化类 |

**判断方法（唯一标准）**：这条数据的**字段名**是否在写代码时就已经确定？

- 是 → 它是记录 → 用类型化类。
- 否 → 它是映射 → 用 Dictionary，且键名从**数据**来，不是从代码约定来。

> 一条记录用 Dictionary 传递，等于把「字段名 + 字段存在性 + 字段类型」三项检查全部外包给运气。

---

## 二、三种写法与取舍

| 方案 | 字段名拼错 | 缺字段 | 字段类型 | 适用 |
|------|-----------|--------|---------|------|
| **类型化数据类**（首选） | 编译期报错 | 不可能（构造即完整） | 编译期检查 | 记录 |
| **键名常量**（次选） | 编译期报错（常量名不存在） | 仍可能（`.get()` 默认值） | 无 | 必须用 Dictionary 的场合 |
| **typed Dictionary** `Dictionary[K, V]` | 不报错 | 仍可能 | 受约束 | 仅用于映射 |

### 2.1 类型化数据类（记录的唯一正解）

```gdscript
@tool
class_name SomeResult
extends RefCounted

## 一句话说明这条记录代表什么。
## 约定：纯数据、构造即完整、"无数据"用 null 表达。

# --- Public Vars ---
var mode: int
var indices: PackedInt32Array


# --- Built-in Functions ---
func _init(p_mode: int, p_indices: PackedInt32Array) -> void:
	mode = p_mode
	indices = p_indices
```

要点（每条都对应一类事故）：

1. **`_init` 参数不给默认值** —— 这是核心。给了 `= 0` / `= []` 就会允许 `new()` 无参构造，于是"忘传字段"重新变成合法的静默错误。无默认值 ⇒ `new()` 直接编译/运行报错。
2. **不写 static 工厂** —— 工厂的价值在于**校验 / 换算 / 多构造变体**。字段直接照搬时，工厂只是多一层跳板，且要写 `类名.new()` 自引用。需要校验时才用工厂。
3. **纯数据类不承载行为** —— 只放字段。`is_empty()`、`to_dict()`、`apply_to()` 这类属于**逻辑**，放调用方或另建工具类。
4. **"空"只用一种表达** —— 选了 `null` 表示"无数据"，就不要再提供 `result.is_empty()` 构成第二套空语义。两者并存时，调用方必然有人只判其一。
5. **依赖方向不可逆** —— `core/` 层的数据类**不得引用上层节点类**（如 `Node3D` 子类）。上层语义（模式枚举等）用 `int` 承载，由上层负责解释。
6. **`class_name` 按需加** —— 不参与类型标注、仅内部使用的数据类，可用 `const Foo = preload("...")` 代替 `class_name`，避免污染全局类表。

**反例（错误示范）**：

```gdscript
# ❌ 无参构造 + 后赋值：允许"半初始化"对象
var result: SomeResult = SomeResult.new()
result.mode = mode
result.indices = indices

# ❌ 静态工厂做纯搬运
static func create(p_mode: int, p_indices: PackedInt32Array) -> SomeResult:
	var result: SomeResult = SomeResult.new()   # 且类内用全名自引用，冗余
	result.mode = p_mode
	result.indices = p_indices
	return result
```

> 注：**类内部 `类名.new()` 本身不是问题**（自查静态工厂返回自身实例是标准做法，不构成循环依赖）。问题只在于「纯数据记录不需要工厂」。

### 2.2 键名常量（必须用 Dictionary 时）

```gdscript
# --- Constants ---
const KEY_VERTEX_COUNT: String = "vertex_count"
const KEY_FACES: String = "faces"
```

- **常量定义方 = 结构生产方**。消费者引用常量的前提是依赖方向合法（低层不引用高层常量）。
- 常量名拼错 → 编译期 `Identifier not found`，比裸字符串强。
- `String` 还是 `StringName`：
  - `StringName`（`&"..."`）比较更快，适合高频查找；
  - 但 **String 与 StringName 作为 Dictionary 键的互换性未在官方文档中承诺**。若链路上仍有字符串字面量键，**统一用 `String` 常量**，不要混用以免"键明明存在却取不到"；
  - 若从生产者到消费者全链路统一 `StringName`，再用 `StringName`。
- 常量无法提供"字段完整性"保障：`.get(key, default)` 仍会静默降级。这是它只能排在次选的原因。

### 2.3 typed Dictionary 不能替代记录

`Dictionary[String, Variant]`（Godot 4.4+）只约束**键与值的类型**，不约束**键的集合**：

```gdscript
var record: Dictionary[String, Variant] = {"mode": 2, "indices": arr}
record.get("mdoe", -1)   # 拼错照样静默返回 -1，编译器不报错
```

结论：它能防「值类型错」，不能防「字段名错」。记录场景仍用类型化类。

---

## 三、`.get(key, default)` 是错误温床

| 场景 | 是否可用 |
|------|---------|
| 映射里键确实可选（如配置项） | ✅ 可以 |
| 记录取字段 | ❌ 绝对禁止 |

理由：记录的字段若缺失，说明**生产方与消费方已经不一致**，这是 bug，必须炸出来。`.get()` 把 bug 变成"用了默认值，悄悄跑下去"。

配套规则：**记录类改完后，`grep 'get("'` 在该结构上应为 0 命中**。

---

## 四、改名 / 重构协议（含真实事故复盘）

**核心规则：改「变量名」和改「字符串键」是两件互不相关的事，必须分别排查。**

某次把节点的公共变量 `mode` 改名为 `select_mode`，同步改了所有引用该变量的脚本，测试却出现 6 条失败：

- 结果字典由 `{"mode": int, "indices": ...}` 生产，键是**字符串**，与变量名无关；
- 生产方（6 个操作类）仍返回 `"mode"`，消费方（主类）与测试已改成读 `"select_mode"`；
- 测试用 `result.get("select_mode", -1)` ⇒ 静默得到 `-1`，断言失败但**无任何报错**；
- 主类用 `p_selection["select_mode"]` ⇒ 键不存在，取到 `null`，`int(null)` = `0` = `VERTEX` ⇒ **每次操作后静默跳到错误模式**（比测试失败更严重）。

**改名检查清单**（任何"重命名"都要走完）：

1. 声明处（变量 / 常量 / 字段）；
2. 所有引用处（`obj.name`、`self.name`、参数名）；
3. **字符串键字面量**（`{"key": ...}`、`dict["key"]`、`dict.get("key", ...)`）；
4. 常量 / 枚举成员；
5. 测试断言、打印与文档注释；
6. **收尾验证**：`grep` 旧名字应 0 命中；对记录结构 `grep 'get("'` 应 0 命中。

---

## 五、把既有 Dictionary 记录改造为类型化类（迁移清单）

1. `grep` 列出生产点（`return {`、`= {`）与消费点（`["key"]`、`.get("key"`、`in dict`）。
2. 新建数据类（字段 + `_init` 无默认参数）。
3. 改生产方：`return {"a": x, "b": y}` → `return SomeRecord.new(x, y)`；"空记录"改为 `return null`。
4. 改消费方：`d["a"]` / `d.get("a", ...)` → `d.a`；并在解引用前加**显式 null 判断**（`if d == null: return`），不要靠 `.get()` 的默认值兜底。
5. 改测试：同样使用字段访问 + 显式 null 判断；**删掉所有 `.get(` **。
6. 收尾：`grep` 该结构的键名字面量应为 0 命中；运行全量测试。

> 迁移期间注意：同一文件里可能有**同名键但不同结构**（如快照的 `"faces"` 与另一模块返回字典的 `"faces"`）。确认结构归属后再替换，不要全局替换。

---

## 六、快速决策

```
需要一个"多条数据"的容器？
├─ 键名在写代码时已固定 ──→ 记录 ──→ 类型化 RefCounted 类（_init 无默认参数、无工厂、无行为）
└─ 键名由数据决定（查找 / 索引 / 缓存）──→ 映射 ──→ Dictionary
        └─ 键名需要在多处书写 ──→ 提为 String 常量（定义在生产者侧）

需要"没有数据"的状态？
└─ 用 null；不要再用 is_empty() 构造第二套空语义

需要类型标注但不想污染全局类表？
└─ const Foo = preload("res://.../foo.gd")
```

---

## 七、速查：反模式 → 改法

| 反模式 | 改法 |
|--------|------|
| `return {"mode": m, "indices": i}` 跨函数传递记录 | 返回 `RefCounted` 记录类实例 |
| `d.get("key", -1) == EXPECTED` 做断言 | `d.key == EXPECTED`（拼错即编译错误） |
| 无参 `new()` + 逐个字段赋值 | `_init` 带无默认值参数，一步构造 |
| 纯搬运的 `static func create()` | 直接 `new(a, b)` |
| 记录类里写 `is_empty()` 且同时用 `null` 表示空 | 二选一，通常留 `null` |
| 裸字符串键散落多处 | 提为 `String` 常量，定义在生产方 |
| `Dictionary[String, Variant]` 冒充记录 | 换成类型化类 |
| `core/` 数据类引用上层节点类取枚举 | 字段用 `int`，语义由上层解释 |
