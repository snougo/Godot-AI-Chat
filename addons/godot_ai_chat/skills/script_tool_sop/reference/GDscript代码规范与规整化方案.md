# Godot AI Chat 插件代码规范与规整化方案

## 1. 变量与命名规范 (Naming Conventions)
*   **公有成员 (Public)**: `variable_name` (蛇形命名，无前缀)。
*   **私有/内部成员 (Private)**: `_variable_name` (下划线前缀)。
*   **函数参数 (Parameters)**: `p_variable_name` (使用 `p_` 前缀，与私有变量严格区分)。
*   **局部变量 (Local)**: `variable_name` (不带前缀)。
*   **布尔值 (Boolean)**: 统一带上前缀，如 `is_ready`, `has_error`, `can_execute`。
*   **信号 (Signals)**: `名词_状态/动作_过去式`，如 `request_completed`, `session_changed`。
*   **常量 (Constants)**: `UPPER_SNAKE_CASE` (全大写蛇形)。

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
13. `# --- Private Functions ---`
14. `# --- Signal Callbacks ---`

## 4. 注释与文档 (Documentation)
*   **类描述**: 在脚本顶部使用 `##` 简述类职责。
*   **公共接口**: 每个公共函数必须有 `##` 注释，描述其作用。
*   **参数说明**: 对于复杂参数，使用 `## [param p_name]: 描述`。
