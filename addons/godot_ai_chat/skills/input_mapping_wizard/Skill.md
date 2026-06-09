# Input Mapping Wizard

## 概览
本技能用于配置 Godot 项目的 InputMap（按键映射）。

## 工作流

1. **解析需求**：识别动作名称和触发事件，调用 `manage_input_map` 工具检查是否已存在映射，避免重复配置。
2. **安全保护**：除非用户明确指定，否则不修改 `ui_` 开头的内置动作；新建动作避免使用 `ui_` 前缀。
3. **生成计划**：将简略指令（如"WASD"）扩展为完整动作组；支持一个动作绑定多个事件。
4. **执行配置**：调用 `manage_input_map` 工具进行配置。
5. **反馈结果**：简要列出已执行的变更。

## 注意事项

- 事件格式使用 Godot API 常量名，如 `KEY_W`、`MOUSE_BUTTON_LEFT`、`JOY_BUTTON_A` 等。
- 组合键使用 `+` 连接，如 `KEY_CTRL+KEY_S`。
