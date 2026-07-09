# Input Mapping Wizard

## 概览
本技能用于配置 Godot 项目的 InputMap（按键映射）。

## 工作流
1. 阅读帮助文档(如果有)。
2. 检视现有的状况。
3. 根据 Main-Agent 发布的任务和现状制定计划。
4. 将计划拆解成执行步骤，并逐一添加成待办事项。
5. 按照顺序执行待办事项直到完成。
6. 检查工作结果，如果符合任务要求则使用 `report_task_result` 进行任务报告，否则继续进行迭代优化。

> 提示：为了节省任务执行所花费的时间和token，无关上下文顺序的操作可以批量进行。

## 注意事项
- 除非 Main-Agent 明确指定，否则不得修改 `ui_` 开头的内置动作，新建动作也禁止使用 `ui_` 前缀。
- 执行过程中遇到错误最多尝试2次，如果依然失败，直接跳过错误部分继续执行后面的部分。

## 帮助文档
`manage_input_map` 工具的详细使用说明，请查阅文档：`res://addons/godot_ai_chat/skills/input_mapping_wizard/reference/manage_input_map_guide.md`
