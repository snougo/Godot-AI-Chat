# Godot 代码书写规范

## 1. 变量与命名规范 (Naming Conventions)
*   **公有成员 (Public)**: `variable_name` (蛇形命名，无前缀)。
	*   判断依据：**能被外部/子类引用的成员一律公共命名**（对外 API 与子类可调用的工具方法）。
*   **私有/内部成员 (Private)**: `_variable_name` (下划线前缀)。
	*   判断依据：类内部实现细节，外部不可引用。
*   **虚接口 (Virtual Interface)**: `_variable_name` (下划线前缀)。
	*   抽象基类中**由子类覆写的虚方法/虚钩子**使用下划线，作为"覆写契约"与对外公共 API 严格区分。
	*   与私有实现同为下划线写法，但语义不同：私有实现不对外、也不期望子类覆写；虚接口是子类必须/可选覆写的契约。
*   **函数参数 (Parameters)**: `p_variable_name` (使用 `p_` 前缀，与私有变量严格区分)。
*   **局部变量 (Local)**: `variable_name` (不带前缀)。
*   **布尔值 (Boolean)**: 统一带上前缀，如 `is_xxx`, `has_xxx`, `can_xxx`。
*   **信号 (Signals)**: `名词_状态/动作_过去式`，如 `request_completed`, `session_changed`。
*   **常量 (Constants)**: `UPPER_SNAKE_CASE` (全大写蛇形)。

### 成员命名判断准则
1. 能被外部/子类引用的成员 → **公共命名**（无下划线）。
2. 子类覆写契约（虚方法/虚钩子）→ **下划线**。
3. 类内部实现（外部不可引用）→ **下划线**。
4. 仅一行转发、无额外逻辑的方法 → **不单独封装**，调用处直接写底层表达式，避免"薄封装冗余"。
5. 计算成本可忽略的中间值 → **不缓存为成员变量**，用实时计算方法代替（无状态原则）。
6. 抽象基类**不承载生命周期流程控制**（如 `_ready` 收集子节点、`_integrate_forces` 施力入口），由子类各自实现；基类只提供能力（工具方法）与虚接口契约。

### 局部变量遮蔽规避（避免 SHADOWED 警告）
局部变量命名**避开基类内置属性与内置全局函数**，否则产生 `SHADOWED_VARIABLE_BASE_CLASS` / `SHADOWED_GLOBAL_IDENTIFIER` 警告：

| 内置标识符 | 推荐替代命名 |
|---|---|
| Node3D 属性 `basis` | `transform_basis` |
| Node3D 属性 `position` / `transform` / `rotation` | `local_pos` / `world_transform` 等语义化替代 |
| 内置全局函数 `sign()` | `heading_sign` / `dir_sign` |
| 其他内置函数（`abs` / `lerp` / `clamp` 等） | 加语义前缀，如 `target_xz`、`angle_diff` |

处理原则：**声明处即避开遮蔽**，而非依赖编译器忽略。

## 2. 静态类型准则 (Static Typing)
*   **显式声明**: 所有变量和函数签名必须包含类型。
	*   变量: `var count: int = 0`
	*   函数: `func process_data(p_input: String) -> Dictionary:`
	*   无返回值: `-> void`
*   **推断类型**: 仅在赋值非常明确时使用 `:=`，如 `var _timer := Timer.new()`。
*   **容器细化**: 必须使用强类型数组，如 `Array[ChatMessage]` 或 `Array[String]`。

## 3. 脚本布局结构 (Script Layout)
每个文件应严格遵守以下顺序，并使用 `# ---` 注释块分割：
1.  `@tool`
2.  `class_name`
3.  `extends`
4.  `## [类文档注释]`
5.  `# --- Signals ---`
6.  `# --- Enums / Constants ---`
7.  `# --- @export Vars ---`
8.  `# --- @onready Vars ---`
9.  `# --- Public Vars ---`
10. `# --- Private Vars ---`
11. `# --- Built-in Functions (_ready, _init 等) ---`
12. `# --- Public Functions ---`
	*   抽象基类可在其后插入 `# --- Virtual Interface ---` 段（虚接口/虚钩子，下划线命名）。
	*   子类覆写基类虚接口时，可用 `# --- Virtual Interface（覆写基类虚接口） ---` 段，置于 Public Functions 之后、Private Functions 之前。
13. `# --- Private Functions ---`
14. `# --- Signal Callbacks ---`

## 4. 注释与文档 (Documentation)
*   **类描述**: 在脚本顶部使用 `##` 简述类职责。
*   **公共接口**: 每个公共函数使用 `##` 注释，描述其作用。
*   **私有接口**: 每个私有函数使用 `#` 注释，描述其作用。
*   **参数说明**: 对于拥有众多且复杂的参数的函数，使用 `## [param p_name]: 描述` 注释其参数。
