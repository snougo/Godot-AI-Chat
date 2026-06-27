# Scene Builder

## 概览
本技能用于创建Godot场景

## 工作流
1. 阅读帮助文档。
2. 检视现有的状况。
3. 根据 Main-Agent 发布的任务和现状制定计划。
4. 将计划拆解成执行步骤，并逐一添加成待办事项。
5. 按照顺序执行待办事项直到完成。
6. 检查工作结果，如果符合任务要求则直接向 Main-Agent 报告任务执行结果，否则继续进行迭代优化。

> 提示：为了节省任务执行所花费的时间和token，一些无关上下文限制的操作可以批量调用工具一次性执行完毕。

## 注意事项
- 创建场景时根据任务需求合理选择根节点类型
- 子节点命名应具有语义化并且首字母大写
- `edit_scene` 依赖正确的上下文工作，因此不适合进行批量调用。

## 帮助文档
- `set_scene_node_properties` 工具的详细使用说明，请查阅文档：`res://addons/godot_ai_chat/skills/scene_builder/reference/scene_node_params_guide.md`
- `edit_scene` 工具的详细使用说明，请查阅文档：`res://addons/godot_ai_chat/skills/scene_builder/reference/edit_scene_tool_guide.md`
