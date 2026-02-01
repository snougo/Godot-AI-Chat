## Input Mapping Wizard

### 概览
本技能旨在通过自然语言交互快速配置 Godot 项目的 InputMap（按键映射）。支持添加动作、绑定物理按键/鼠标按钮/手柄摇杆，并能自动处理常见的游戏控制模式。

### 触发条件
当用户请求配置按键、绑定操作或修改输入映射时（例如：“把空格设为跳跃”，“WASD设为上下左右移动”）。

### 指令
1. **解析需求**：
	- 识别用户意图中的“动作名称”（Action）和“触发事件”（Event）。
	- 归一化动作名称（推荐使用 `snake_case`，如 `move_forward`, `jump`, `attack`）。
	- 识别具体的物理按键、鼠标按键或手柄按键（JoyBtn/JoyAxis）。

2. **安全与保护原则（重要）**：
	- **避让内置动作**：除非用户明确指定要修改以 `ui_` 开头的动作（如 `ui_accept`, `ui_cancel`），否则生成的配置列表**绝不**应包含这些动作。
	- **避免同名冲突**：如果是新建游戏动作，尽量避免使用 `ui_` 前缀，以免意外覆盖引擎默认行为。

3. **生成配置计划**：
	- **处理简略指令**：如“WASD 移动”应扩展为 `move_forward/backward/left/right` 四个动作。
	- **多事件绑定**：如“跳跃是空格或手柄A键”，应在一个动作下生成两个事件。

4. **执行配置**：
	- 调用 `manage_input_map` 工具。
	- 参数构建：
		- `action_name`: 动作名称。
		- `events`: 事件描述数组（支持 `Key:X`, `Mouse:Left`, `JoyBtn:A`, `JoyAxis:Left_X-` 等）。
		- `clear_existing`: 默认为 `true`（覆盖模式）。

5. **反馈结果**：
	- 简要列出已执行的变更（如：“已配置 'jump' 绑定到 Space 和 JoyBtn:A”）。

### 示例
**用户**：帮我把 WASD 设为移动，空格跳跃，鼠标左键攻击。
**助手**：正在配置输入映射...
[调用工具 manage_input_map，参数如下]
- actions: 
  - { name: "move_forward", events: ["Key:W"] }
  - { name: "jump", events: ["Key:Space"] }
  - { name: "attack", events: ["Mouse:Left"] }
完成！已安全更新项目输入设置（未触碰内置 ui_* 动作）。
