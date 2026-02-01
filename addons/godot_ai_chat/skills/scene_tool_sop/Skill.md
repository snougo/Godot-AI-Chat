## Scene Tool SOP

### 概览
本技能旨在规范 Godot 场景与节点操作工具的使用流程。由于场景数据的复杂性和状态依赖性，必须严格遵循“观察-决策-行动”的单步循环模式，严禁盲目操作或批量执行。

### 触发条件
当用户请求创建场景文件、修改节点层级结构（添加/删除/移动）、或编辑节点属性时。

### 指令
1. **核心原则：单步执行 (One Step at a Time)**
   - **禁止**在一个回复中连续调用多个场景工具（如同时创建场景和添加节点）。
   - **必须**等待每一个工具执行完毕并返回结果（特别是场景树结构），再根据结果生成下一步的工具调用。

2. **标准工作流**
   - **阶段一：场景接入 (Access)**
	 - **动作**：调用 `manage_scene_file` (action="open" 或 "create")。
	 - **目的**：确保编辑器当前激活的是目标场景。
	 - **注意**：如果是 create，需要提供 `root_node_type`。

   - **阶段二：结构分析 (Analyze)**
	 - **动作**：调用 `manage_scene_structure` (action="get_scene_tree")。
	 - **目的**：获取当前场景的完整节点树结构，确认父节点路径和节点名称。
	 - **禁止**：在未获取树结构的情况下盲猜节点路径。

   - **阶段三：执行修改 (Modify)**
	 - **结构修改**：
	   - 调用 `manage_scene_structure` (action="add_node" / "delete_node" / "move_node")。
	   - **参数**：`node_path` 和 `parent_path` 必须是基于根节点的相对路径（如 "Player/Sprite"），不要包含 "/root/"。
	 - **属性修改**：
	   - **前置**：先调用 `access_node_properties` (action="check_node_property") 确认属性名和类型。
	   - **执行**：调用 `saccess_node_properties` (action="set_node_property")。
	   - **格式**：Vector/Color 使用数组格式字符串（如 "[1, 0, 0]"），资源使用 "res://" 路径。

3. **路径与参数规范**
   - **节点路径**：使用相对于场景根节点的路径（例如 `Player/Sprite`）。根节点本身路径为 `.`。
   - **资源路径**：涉及 `PackedScene` 或 `Script` 时，必须使用 `res://` 全路径。

### 拓展引用
如需深入了解不同类型场景的搭建规范，请查阅 `res://addons/godot_ai_chat/skills/scene_tool_sop/reference/` 文件夹中的引用文件。

### 示例

**添加节点流程：**
1. 用户："给 Player 场景加一个 Sprite"
2. AI 调用 `scene_manager(action="open", scene_path="res://player.tscn")`
3. (等待工具返回) -> 工具返回场景已打开
4. AI 调用 `scene_node_manager(action="get_scene_tree")`
5. (等待工具返回) -> 工具返回树结构，确认根节点为 `Player`
6. AI 调用 `scene_node_manager(action="add_node", parent_path=".", node_class="Sprite2D", node_name="Sprite")`

**修改属性流程：**
1. 用户："把 Sprite 变红"
2. AI 调用 `scene_inspector(action="check_node_property", node_path="Sprite", property_name="modulate")`
3. (等待工具返回) -> 工具返回当前颜色
4. AI 调用 `scene_inspector(action="set_node_property", node_path="Sprite", property_name="modulate", value="[1, 0, 0, 1]")`
