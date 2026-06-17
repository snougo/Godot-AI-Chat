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

## 工具使用解释
`multi_replace` 的详细使用说明见前置文档 `res://addons/godot_ai_chat/skills/script_editor/reference/multi_replace_tool_guide.md`

## 注意事项

- 所有编辑操作仅对当前脚本编辑器中打开的脚本文件生效，所以确保编辑前先打开目标脚本。
- `insert_code` 和 `delete_code` 基于正确的行号工作，而 `multi_replace` 虽然基于字符匹配来工作，不过这三者的编辑都会造成现有的编辑对象的行号对应的代码内容发生改变，所以这三个工具只能各自单独单次进行调用。
- 所有编辑操作不会应用给磁盘上的脚本文件，而只是改变了脚本文件在内存中的状态。
- `get_edited_script` 会返回编辑后的最新状态，适合用来查看编辑中文件的修改状态。
- `read_file` 只会返回磁盘上脚本文件原始状态，不适合用来查看编辑中文件的修改状态。
