# Scene Builder

## 概览
本技能用于创建Godot场景

## 工作流

1. **前期规划**：
   - 分析用户需求，确定根节点类型（Node2D / Node3D / Control 等）和场景用途
   - 规划节点层级结构（父/子关系）和每个节点所需配置的属性

2. **创建场景文件**：
   - 使用 `manage_folder` 确认目标文件夹存在，如果不存在则先创建目标文件夹。
   - 使用 `create_file` 创建目标场景文件

3. **打开场景**：
   - 使用 `open_file` 打开刚创建的场景，使其成为编辑器当前激活场景
   - 使用 `get_edited_scene` 查看当前打开的场景的节点结构

4. **搭建节点层级**：
   - 使用 `edit_scene` 逐个添加/删除/移动节点

1. **配置节点属性**：
   - 先使用 `get_scene_node_properties` 先获取目标节点的当前属性
   - 随后使用 `set_scene_node_properties` 设置目标节点属性

6. **确认结果**：
   - 使用 `get_edited_scene` 获取最终场景树，进行确认

## 工具使用解释
如何正确获取/设置节点属性请查看前置文档：`res://addons/godot_ai_chat/primers/scene_node_params_guide.md`

## 注意事项
 
- 创建场景时合理选择根节点类型：2D 游戏用 `Node2D`，3D 游戏用 `Node3D`，UI 用 `Control`
- 子节点命名应具有语义化（如 `Player`、`Background`、`UI_ScoreLabel`）
- 每次 `edit_scene` 操作前，使用场景树中返回的节点路径格式（如 `Player/Body/Sprite`）
- 如需设置材质/纹理等资源引用，先确认资源路径是否存在
- 切勿使用 `read_file` 获取编辑中的场景节点结构，而应该使用 `get_edited_scene`
