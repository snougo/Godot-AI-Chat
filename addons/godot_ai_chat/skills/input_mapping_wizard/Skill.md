## Input Mapping Wizard

### 概览
本技能用于配置指定的 Godot 项目的 InputMap（按键映射）。

1. **解析需求**：
	- 识别用户意图中的"动作名称"（Action）和"触发事件"（Event）。
	- 调用 `manage_input_map` 工具并使用 `list` 操作参数检查是否已经存在对应的按键映射，如果已经存在，则跳过不进行重复配置。
	- 归一化动作名称（推荐使用 `snake_case`，如 `move_forward`, `jump`, `attack`）。
	- 识别具体的物理按键、鼠标按键或手柄按键。

2. **安全与保护原则（重要）**：
	- **避让内置动作**：除非用户明确指定要修改以 `ui_` 开头的动作（如 `ui_accept`, `ui_cancel`），否则生成的配置列表**绝不**应包含这些动作。
	- **避免同名冲突**：如果是新建游戏动作，避免使用 `ui_` 前缀，以免意外覆盖引擎的同名内建值。

3. **生成配置计划**：
	- **处理简略指令**：如"WASD 移动"应扩展为 `move_forward/backward/left/right` 四个动作。
	- **多事件绑定**：如"跳跃是空格或手柄A键"，应在一个动作下生成两个事件。

4. **执行配置**：
	- 调用 `manage_input_map` 工具。
	- 参数构建：
		- `operation`: 操作类型（`add`/`update`/`remove`/`list`/`clear`）。
		- `actions`: 动作数组，每个动作包含：
			- `name`: 动作名称。
			- `events`: 事件描述数组，使用 Godot API 常量格式：
			- `clear_existing`: 默认为 `true`（覆盖模式）。

5. **反馈结果**：
	- 简要列出已执行的变更（如："已配置 'jump' 绑定到 KEY_SPACE 和 JOY_BUTTON_A"）。

### 事件格式速查表

| 类型 | 格式示例 | 说明 |
|------|----------|------|
| 单键 | `KEY_W`, `KEY_SPACE`, `KEY_ENTER` | 直接使用 KEY_* 常量名 |
| 组合键 | `KEY_CTRL+KEY_S`, `KEY_SHIFT+KEY_TAB` | 使用 + 连接修饰键和主键 |
| 鼠标 | `MOUSE_BUTTON_LEFT`, `MOUSE_BUTTON_RIGHT` | 完整的 MOUSE_BUTTON_* 常量名 |
| 滚轮 | `MOUSE_BUTTON_WHEEL_UP`, `MOUSE_BUTTON_WHEEL_DOWN` | 滚轮上下滚动 |
| 手柄按钮 | `JOY_BUTTON_A`, `JOY_BUTTON_START` | 标准手柄按键 |
| 手柄摇杆 | `JOY_AXIS_LEFT_X`, `JOY_AXIS_RIGHT_X` | 轴名 + 方向后缀 |

### 示例

**用户**：手柄控制：左摇杆移动，A键跳跃，右肩键攻击。

**助手**：正在配置手柄输入映射...
[调用工具 manage_input_map，参数如下]
- operation: "add"
- actions:
  - { name: "move_left", events: ["JOY_AXIS_LEFT_X"] }
  - { name: "move_right", events: ["JOY_AXIS_RIGHT_X"] }
  - { name: "move_up", events: ["JOY_AXIS_LEFT_Y"] }
  - { name: "move_down", events: ["JOY_AXIS_RIGHT_Y"] }
  - { name: "jump", events: ["JOY_BUTTON_A"] }
  - { name: "attack", events: ["JOY_BUTTON_RIGHT_SHOULDER"] }

完成！已配置手柄输入映射。
