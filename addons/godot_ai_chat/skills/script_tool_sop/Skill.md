## Script Tool SOP

### 概览
本技能指导如何正确、高效地使用基于**直接行操作**的脚本修改工具链。核心工作流为：**打开 -> 获取 -> 删除/插入**。

### 触发条件
当用户请求修改、重构、插入或创建 GDScript/GDShader 代码时。

### 指令
1. **创建新脚本（如果需要）**
   - 直接调用 `create_script`
   - 提供完整参数：folder_path, file_name, content
   - 工具会自动打开新脚本并返回内容视图

2. **修改现有脚本**
   - **第一步：打开目标脚本（如未打开）**
	 - 调用 `open_script_in_editor(file_path="res://xxx/xxx.gd")`
	 - 目的：确保目标脚本在编辑器中已打开
   
   - **第二步：获取上下文**
	 - 必须调用 `get_edited_script`
	 - 目的：获取当前脚本的完整内容和行号信息
	 - **禁止**在未读取的情况下直接盲猜行号
   
   - **第三步：执行修改**
	 - **删除/插入二选一**：
	   - 场景 A：修改现有代码 → `delete_code_range` + `insert_code`
	   - 场景 B：添加新代码 → `insert_code`

### 拓展知识
如需深入了解代码书写规范等事项，请查阅 `res://addons/godot_ai_chat/skills/script_tool_sop/reference/` 文件夹中的相关文档。

### 示例
**修改脚本流程：**
```
用户："修改 player.gd 的 _process 函数"

1. AI → open_script_in_editor(file_path="res://player.gd")
2. AI → get_edited_script (返回完整代码视图)
3. AI 分析视图，找到目标行号（如第 15-20 行）
4. AI → delete_code_range(start_line=15, end_line=20)
5. AI 收到更新后的视图，确认删除完成
6. AI → insert_code(target_line=15, new_content="func _process(delta):\n\t...")
```

**插入代码流程：**
```
用户："在 player.gd 增加 jump 函数"

1. AI → open_script_in_editor(file_path="res://player.gd")
2. AI → get_edited_script (返回完整代码视图)
3. AI 找到合适空行（如第 25 行）
4. AI → insert_code(target_line=25, new_content="func jump():\n\t...")
```

**创建新脚本流程：**
```
用户："创建一个新的 player_controller.gd"

AI → create_script(
	folder_path="res://scripts/",
	file_name="player_controller.gd",
	content="// 完整代码内容..."
)
```

**参数详解：**

| 工具名称 | 参数 | 说明 |
|---------|------|------|
| `open_script_in_editor` | file_path (String) | 脚本文件完整路径（如 res://xxx/xxx.gd） |
| `get_edited_script` | - | 无参数，获取当前脚本编辑器中打开的脚本 |
| `create_script` | folder_path, file_name, content (String) | 创建新脚本并写入初始代码 |
| `delete_code_range` | start_line, end_line (Integer) | 删除指定行范围的代码（1-based） |
| `insert_code` | target_line (Integer), new_content (String) | 在指定空行插入新代码 |

**最佳实践：**
1. **安全校验**：所有工具都内置路径安全性检查，受限路径将无法进行写入
2. **行号基数**：所有工具使用 **1-based 行号**（非 0-based）
3. **空行原则**：`insert_code` **只能**在**空行**操作
4. **原子性**：修改是独立操作，删除后需重新获取视图再插入
5. **扩展名限制**：仅允许 `.gd` 和 `.gdshader` 文件
