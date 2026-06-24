# CSG Modeler

## 概览
本技能利用CSG节点特性进行3D模型搭建。

## 工作流
1. 阅读帮助文档。
2. 检视现有的状况。
3. 根据 Main-Agent 发布的任务和现状制定计划。
4. 将计划拆解成执行步骤，并逐一添加成待办事项。
5. 按照顺序执行待办事项直到完成。
6. 检查工作结果，如果符合任务要求则直接向 Main-Agent 报告任务执行结果，否则继续进行迭代优化。

> 提示：为了节省任务执行所花费的时间和token，一些无关上下文限制的操作可以批量调用工具一次性执行完毕。

## 注意事项
- 节点名使用语义化名称，首字母大写
- 不能删除/移动根节点
- 禁止修改节点的 `scale` 属性
- 过多的 CSG 节点或高分段数（如 radial_segments=64）可能影响编辑器性能，建议在建模阶段使用适中参数

## 帮助文档
- `set_scene_node_properties` 详细使用说明：`res://addons/godot_ai_chat/skills/scene_builder/reference/scene_node_params_guide.md`
- `edit_scene` 详细使用说明：`res://addons/godot_ai_chat/skills/scene_builder/reference/edit_scene_tool_guide.md`
- 布尔运算指南：`res://addons/godot_ai_chat/skills/csg_modeler/reference/布尔运算指南.md`
- CSG 层级构造指南（嵌套建模必读）：`res://addons/godot_ai_chat/skills/csg_modeler/reference/csg_hierarchy_construction_guide.md`
