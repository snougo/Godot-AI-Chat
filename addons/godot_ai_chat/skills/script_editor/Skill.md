# Script Editor

## 概览
本技能用于对项目中的脚本文件进行创建、打开、读取和修改操作。

## 工作流

1. **定位**：用 `manage_folder` 确认目标所在文件夹是否存在，如果不存在则先创建目标文件夹。
2. **创建/打开**：用 `create_file` 新建脚本，或用 `open_file` 打开已有脚本
3. **读取**：用 `get_edited_script` 获取当前脚本内容
4. **编辑**：
   - 单处删除或插入编辑 → `insert_code` 或 `delete_code`
   - 多处同时替换编辑 → `multi_replace`
5. **确认**：使用 `get_edited_script` 确认修改结果。

## 帮助文档
`multi_replace` 工具的详细使用说明，请查阅文档 `res://addons/godot_ai_chat/skills/script_editor/reference/multi_replace_tool_guide.md`

## 注意事项

- 所有编辑操作仅对当前脚本编辑器中打开的脚本文件生效，所以确保编辑前先打开目标脚本。
- `insert_code` 和 `delete_code` 工具基于行号工作，其功能也会造成行数变化和行代码内容改变，因此不适合连续调用或者混合调用。
- `read_file` 无法获取脚本编辑后的状态，应当使用 `get_edited_script` 获取。
