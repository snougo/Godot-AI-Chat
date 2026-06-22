# PBR Material Builder

## 概览
自动化PBR材质的创建

## 工作流

1. **确定贴图文件夹**：根据任务描述确定存放 PBR 贴图的文件夹路径。

2. **检查文件夹**：调用 `manage_folder` 确认目标文件夹存在，如果文件夹不存在则直接中止，并进行报告。

3. **检查文件尺**：调用 `read_file` 和 `view_image(可选)` 确认贴图尺寸和内容。

4. **修复文件名**：如果发现贴图文件名不符合工具的自动识别规则，调用 `rename_file` 将其命名规范化。

5. **生成材质**：调用 `generate_pbr_material` 在目标文件夹中会自动生成对应的PBR材质。

6. **报告**：使用 `report_task_result` 报告结果，列出生成了哪些材质文件。

## 帮助文档
关于PBR贴图文件名的自动识别规则请查阅：`res://addons/godot_ai_chat/skills/pbr_material_builder/reference/pbr_texture_guide.md`

## 注意事项
- 如果材质文件已存在，工具会自动跳过，不会覆盖
- 贴图的颜色空间设置（Albedo=sRGB, Normal/ORM=Linear）需要在 Godot 导入设置中手动配置，工具不会自动修改导入配置
- `view_image` 只支持具有视觉能力的模型，如果你不具备视觉能力，请勿调用。
