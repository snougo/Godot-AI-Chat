# Script Editor

## 概览
本技能用于对项目中的脚本文件进行创建、打开、读取和修改操作。

## 工作流

1. **定位**：用 `manage_folder` 确认目标所在文件夹是否存在，如果不存在则先创建目标文件夹。
2. **创建/打开**：用 `create_file` 新建脚本，或用 `open_file` 打开已有脚本
3. **读取**：用 `get_edited_script` 获取当前脚本内容
4. **编辑**：
   - 单处简单编辑 → `insert_code` 或 `delete_code_range`
   - 多处同时编辑 → `batch_edit`
5. **确认**：每次编辑后都会返回带行号的完整脚本内容

## 工具使用解释
`batch_edit` 的详细使用说明见前置文档 `res://addons/godot_ai_chat/primers/batch_edit_tool_guide.md`

## 注意事项

- 所有编辑操作仅对当前脚本编辑器中的文件生效
- 如需连续多步编辑，请基于上一步返回的新行号规划下一步
- 切勿使用 `read_file`读取编辑中的脚本内容，而应该使用 `get_edited_script`
