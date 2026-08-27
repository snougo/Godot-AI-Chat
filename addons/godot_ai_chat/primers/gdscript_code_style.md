# GDScript 代码风格规范

## 命名规范

| 类别 | 格式 | 说明 / 示例 |
|------|------|-------------|
| 公有成员 | `variable_name` | 能被外部/子类引用 |
| 私有成员 | `_variable_name` | 类内部实现细节，外部不可引用 |
| 虚接口（子类覆写契约） | `_variable_name` | 抽象基类虚方法；与私有写法相同，但语义为"覆写契约" |
| 函数参数 | `p_variable_name` | 使用 `p_` 前缀，与私有变量严格区分 |
| 局部变量 | `variable_name` | 无前缀 |
| 布尔值 | `is_ / has_ / can_` 前缀 | 如 `is_ready`, `has_data`, `can_run` |
| 信号 | `名词_状态/动作_过去式` | 如 `request_completed`, `session_changed` |
| 常量 | `UPPER_SNAKE_CASE` | 全大写蛇形 |

### 成员命名判断准则
1. 能被外部/子类引用的成员 → **公有命名**（无下划线）。
2. 子类覆写契约（虚方法/虚钩子）→ **下划线**。
3. 类内部实现（外部不可引用）→ **下划线**。
4. 仅一行转发、无额外逻辑的方法 → **不单独封装**，调用处直接写底层表达式。
5. 计算成本可忽略的中间值 → **不缓存为成员变量**，用实时计算方法代替（无状态原则）。
6. 抽象基类**不承载生命周期流程控制**（如 `_ready` 收集子节点），只提供能力（工具方法）与虚接口契约，由子类各自实现。

### 局部变量遮蔽规避
- 局部变量命名**避开基类内置属性与内置全局函数**，否则触发 `SHADOWED_VARIABLE_BASE_CLASS` / `SHADOWED_GLOBAL_IDENTIFIER` 警告。
- 原则：**声明处即避开**，而非依赖编译器忽略。

## 静态类型
- 所有变量与函数签名必须**显式声明类型**；无返回值一律 `-> void`。
  - `var count: int = 0`
  - `func process_data(p_input: String) -> Dictionary:`
- 仅赋值非常明确时使用 `:=` 推断（如 `var _timer := Timer.new()`）。
- 容器必须使用**强类型数组**，如 `Array[String]`。

## 脚本布局
每个文件按以下顺序组织，并用 `# ---` 注释块分割：

1. `@tool`
2. `class_name`
3. `extends`
4. `## [类文档注释]`
5. `# --- Signals ---`
6. `# --- Enums / Constants ---`
7. `# --- @export Vars ---`
8. `# --- @onready Vars ---`
9. `# --- Public Vars ---`
10. `# --- Private Vars ---`
11. `# --- Built-in Functions (_ready, _init 等) ---`
12. `# --- Public Functions ---`
13. `# --- Private Functions ---`
14. `# --- Signal Callbacks ---`

> 抽象基类可在其后插入 `# --- Virtual Interface ---` 段（虚接口/虚钩子，下划线命名）。
> 子类覆写基类虚接口时，用 `# --- Virtual Interface（覆写基类虚接口） ---` 段，置于 Public Functions 之后、Private Functions 之前。

## 注释与文档
- **类描述**：脚本顶部用 `##` 简述类职责。
- **公共接口**：每个公共函数用 `##` 注释，描述其作用。
- **私有接口**：每个私有函数用 `#` 注释，描述其作用。
- **参数说明**：参数众多且复杂时，用 `## [param p_name]: 描述` 逐一注释。