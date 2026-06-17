# Scene Builder

## 概览
本技能用于创建Godot场景

## 工作流

1. **前期规划**：分析用户需求，确定根节点类型和场景用途

2. **创建场景文件**：使用 `manage_folder` 确认目标文件夹是否存在，如果存在使用 `create_file` 创建目标场景文件

3. **打开场景**：使用 `open_file` 打开创建的场景，并使用 `get_edited_scene` 查看当前打开的场景的节点结构

4. **搭建节点层级**：使用 `edit_scene` 逐个添加/删除/移动节点

5. **配置节点属性**：
   - 先使用 `get_scene_node_properties` 先获取目标节点的当前属性
   - 随后使用 `set_scene_node_properties` 设置目标节点属性

6. **确认结果**：
   - 使用 `get_edited_scene` 查看编辑后的场景树结构，进行确认

## 工具使用解释
如何正确获取/设置节点属性请查看前置文档：`res://addons/godot_ai_chat/skills/scene_builder/reference/scene_node_params_guide.md`

## 注意事项
 
- 创建场景时合理选择根节点类型：2D 游戏用 `Node2D`，3D 游戏用 `Node3D`，UI 用 `Control`
- 子节点命名应具有语义化并且首字母大写（如 `Player`、`Background` etc）
- 每次 `edit_scene` 操作前，使用场景树中返回的节点路径格式（如 `Player/Body/Sprite`）
- 所有编辑操作不会应用给磁盘上的脚本文件，而只是改变了脚本文件在内存中的状态。
- `get_edited_scene` 会返回编辑后的最新状态，适合用来查看编辑中文件的修改状态。
- `read_file` 只会返回磁盘上脚本文件原始状态，不适合用来查看编辑中文件的修改状态。
- 如需设置材质/纹理等资源引用，先确认资源是否存在
