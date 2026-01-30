## Script Tool SOP

### 概览
本技能旨在指导如何正确、高效地使用基于切片（Slice-based）的脚本修改工具链。核心工作流为：**读取 (Read) -> 定位 (Locate) -> 修改 (Modify)**。

### 触发条件
当用户请求修改、重构、插入或创建 GDScript/Shader 代码时。

### 指令
1. **修改现有脚本 (Modify Existing Script)**
   - **第一步：获取上下文 (Mandatory)**
	 - **必须**先调用 `get_script_slices`。
	 - **目的**：获取最新的代码结构、行号和切片。
	 - **禁止**：在未读取最新切片视图的情况下直接盲猜行号或签名。
   - **第二步：分析切片视图**
	 - 查看工具返回的 `### Script Structure View`。
	 - 找到目标逻辑所在的 `[Slice ID]`。
	 - 找到目标切片的 `signature`（例如 `func fun_name():`、`var var_name: xxxx = xxx` 或 `signal xxxxxxxx` 等，以此类推）。
   - **第三步：执行修改**
	 - **情况 A：修改现有逻辑**
	   - 使用 `rewrite_script_slice`。
	   - 参数 `target_signature`: 填入从视图中获取的签名。
	   - 参数 `new_content`: 填入重写后的切片代码（包含函数头、缩进等）。
	 - **情况 B：添加新逻辑**
	   - 在视图中寻找合适的**空行**行号（通常在两个切片之间）。
	   - 使用 `insert_new_slice`。
	   - 参数 `target_line`: 填入空行行号。
	   - 参数 `new_content`: 填入新代码。

2. **创建新脚本 (Create New Script)**
   - 直接调用 `create_script`。
   - 提供完整的初始代码内容。
   - 工具会自动打开并返回切片视图，无需再次调用 `get_script_slices`。

3. **最佳实践**
   - **签名匹配优先**：`rewrite_script_slice` 依赖签名匹配。如果签名很长，可以使用前缀。
   - **完整覆盖**：`rewrite_script_slice` 是**全量替换**该切片，不要遗漏函数定义行。
   - **插入安全**：`insert_new_slice` 只能在**空行**操作。

### 拓展引用
如需深入了解代码书写规范等事项，请查阅 `res://addons/godot_ai_chat/skills/script_tool_sop/reference/` 文件夹中的引用文件。

### 示例

**修改脚本流程：**
1. 用户："修改 player.gd 的 _process 函数"
2. AI 调用 `get_script_slices(path="res://player.gd")`
3. AI 收到切片视图，看到 `func _process(delta):` 在 Slice 5
4. AI 调用 `rewrite_script_slice(target_signature="func _process(delta):", new_content="...")`

**插入代码流程：**
1. 用户："在 player.gd 增加一个 jump 函数"
2. AI 调用 `get_script_slices(path="res://player.gd")`
3. AI 收到切片视图，发现 Slice 5 和 Slice 6 之间有空行（Line 20）
4. AI 调用 `insert_new_slice(target_line=20, new_content="func jump():\n\t...")`
