# Input Mapping Wizard

## 概览
本技能用于配置 Godot 项目的 InputMap（按键映射）。

## 工作流

1. **解析需求**：识别动作名称和触发事件。
2. **检查冲突**：调用 `manage_input_map`（operation: `list`）查看现有动作，避免重复创建。
3. **生成计划**：将简略指令（如"WASD"）扩展为完整动作组。
4. **执行配置**：
   - 新建动作 → `manage_input_map`（operation: `add`）
   - 删除动作 → `manage_input_map`（operation: `remove`）
   - 修改动作 → 先 `remove` 再 `add`
5. **反馈结果**：简要列出已执行的变更。

## 帮助文档
`manage_input_map` 工具的详细使用说明，请查阅文档：`res://addons/godot_ai_chat/skills/input_mapping_wizard/reference/manage_input_map_guide.md`

## 注意事项

- 安全保护：除非用户明确指定，否则不修改 `ui_` 开头的内置动作，新建动作也禁止使用 `ui_` 前缀。
