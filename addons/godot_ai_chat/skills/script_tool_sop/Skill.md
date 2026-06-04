## Script Tool SOP

### 概览
本技能指导如何正确、高效地使用基于**直接行操作**的脚本修改工具链。核心工作流为：**打开 -> 获取 -> 删除/插入**。

### 触发条件
当用户请求修改、重构、插入或创建 GDScript/GDShader 代码时。

### 指令
1. **创建新脚本（如果需要）**
   - 直接调用 `create_file`
   - 提供完整参数：folder_path, file_name, content
   - 工具会自动打开新脚本并返回内容视图

2. **修改现有脚本**
   - **第一步：打开目标脚本（如未打开）**
	 - 调用 `open_file`
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
如需深入了解代码风格指导等细节，请查阅 `res://addons/godot_ai_chat/skills/script_tool_sop/reference/` 文件夹中的相关文档。

### 示例
**修改脚本流程：**
```
用户："修改 player.gd 的 _process 函数"

1. AI → open_file(file_path="res://player.gd")
2. AI → get_edited_script (返回完整代码视图)
3. AI 分析视图，找到目标行号（如第 15-20 行）
4. AI → delete_code_range(start_line=15, end_line=20)
5. AI 收到更新后的视图，确认删除完成
6. AI → insert_code(target_line=15, new_content="func _process(delta):\n\t...")
```

**插入代码流程：**
```
用户："在 player.gd 增加 jump 函数"

1. AI → open_file(file_path="res://player.gd")
2. AI → get_edited_script (返回完整代码视图)
3. AI 找到合适空行（如第 25 行）
4. AI → insert_code(target_line=25, new_content="func jump():\n\t...")
```

**创建新脚本流程：**
```
用户："创建一个新的 player_controller.gd"

AI → create_file(
	file_type="script"
	path="res://scripts/",
	file_name="player_controller.gd",
	content="// 完整代码内容..."
)
```

**核心工具参数详解：**

| 工具名称 | 参数 | 说明 |
|---------|------|------|
| `delete_code_range` | start_line, end_line (Integer) | 删除指定行范围的代码（1-based） |
| `insert_code` | target_line (Integer), new_content (String) | 在指定空行插入新代码 |

**最佳实践：**
1. **安全校验**：所有工具都内置路径安全性检查，受限路径将无法进行写入
2. **行号基数**：所有工具使用 **1-based 行号**（非 0-based）
3. **空行原则**：`insert_code` **只能**在**空行**操作
4. **原子性**：删除、插入都是独立操作，必须遵循线性流程，不可同时进行。
