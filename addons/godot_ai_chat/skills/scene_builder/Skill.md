# Scene Builder

## 概览
本技能用于创建Godot场景

## 工作流

1. **前期规划**：分析用户需求，确定根节点类型和场景用途
2. **创建场景文件**：使用 `manage_folder` 确认目标文件夹是否存在，如果存在使用 `create_scene` 创建目标场景文件
3. **打开场景**：使用 `open_file` 打开创建的场景，并使用 `get_edited_scene` 查看当前打开的场景的节点结构
4. **搭建节点层级**：使用 `edit_scene` 逐个添加/删除/移动节点
5. **配置节点属性**：首先使用 `get_scene_node_properties` 获取目标节点的当前属性，然后使用 `set_scene_node_properties` 设置目标节点属性
6. **确认结果**：使用 `get_edited_scene` 确认编辑后的场景树结构

## 帮助文档
 `set_scene_node_properties` 工具的详细使用说明，请查阅文档：`res://addons/godot_ai_chat/skills/scene_builder/reference/scene_node_params_guide.md`
 `edit_scene` 工具的详细使用说明，请查阅文档：`res://addons/godot_ai_chat/skills/scene_builder/reference/edit_scene_tool_guide.md`

## 注意事项
 
- 创建场景时根据任务需求合理选择根节点类型
- 子节点命名应具有语义化并且首字母大写
