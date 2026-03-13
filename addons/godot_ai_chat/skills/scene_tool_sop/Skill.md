## Scene Tool SOP

### 概览
本技能旨在规范 Godot 场景与节点操作工具的使用流程。由于场景数据的复杂性和状态依赖性，必须严格遵循"观察-决策-行动"的单步循环模式，严禁盲目操作或批量执行。

### 触发条件
当用户请求创建场景文件、修改节点层级结构（添加/删除/移动）、或编辑节点属性时。

### 指令

#### 1. 核心原则：单步执行 (One Step at a Time)
- **禁止**在一个回复中连续调用多个场景工具（如同时创建场景和添加节点）。
- **必须**等待每一个工具执行完毕并返回结果（特别是场景树结构），再根据结果生成下一步的工具调用。

#### 2. 标准工作流

##### 阶段一：场景接入 (Access)
- **动作**：调用 `manage_scene_file` (action="open" 或 "create")。
- **目的**：确保编辑器当前激活的是目标场景。
- **注意**：如果是 create，需要提供 `root_node_type`。

##### 阶段二：结构分析 (Analyze)
- **动作**：调用 `get_edited_scene` 。
- **目的**：获取当前场景的完整节点树结构，确认父节点路径和节点名称。
- **禁止**：在未获取树结构的情况下盲猜节点路径。

##### 阶段三：执行修改 (Modify)

###### 结构修改
- 调用 `manage_scene_structure` (action="add_node" / "delete_node" / "move_node")。
- **参数**：`node_path` 和 `parent_path` 必须是基于根节点的相对路径（如 "Player/Sprite"），不要包含 "/root/"。

###### 属性查看
- 调用 `get_node_properties` (node_path="目标节点路径") 确认属性名和类型。
- 特别关注返回结果中 Resource 类型的 `properties` 字段，了解子资源可调属性。

###### 属性修改
- 调用 `set_node_properties` (node_path, property_name, value)。
- **格式**：Vector/Color 使用数组格式字符串（如 "[1, 0, 0]"），资源使用 "res://" 路径。

#### 3. 路径格式规范（关键）

##### ⚠️ 节点路径 vs 资源属性路径 - 完全不同！

| 场景 | 格式 | 示例 | 说明 |
|------|------|------|------|
| **查找节点** | 斜杠 `/` | `Player/Body` | 用于 `node_path` 参数定位场景中的节点 |
| **子资源属性** | 冒号 `:` | `Body:mesh:height` | 用于 `property_name` 参数访问嵌套资源属性 |

**常见错误**：❌ `TestCapsule/mesh/height` （用斜杠访问资源属性）
**正确写法**：✅ `TestCapsule:mesh:height` （用冒号访问资源属性）

##### 路径格式详细规则

**节点路径**（`node_path` 参数）：
- 使用斜杠 `/` 分隔层级：`Parent/Child/GrandChild`
- 根节点路径为 `.`
- 用于：定位要操作的节点

**子资源属性路径**（`property_name` 参数）：
- 使用冒号 `:` 分隔层级：`node:resource:sub_property`
- 用于：访问节点属性中 Resource 类型的内部属性
- 支持多级嵌套：`mesh:material:albedo_color`

#### 4. 资源创建与修改

##### 创建新资源实例
- 使用 `new:ClassName` 格式作为 value
- 示例：`mesh = "new:CapsuleMesh"`、`shape = "new:BoxShape3D"`

##### 修改子资源属性
1. 先创建资源（如 `mesh = "new:CapsuleMesh"`）
2. 再设置子属性（如 `mesh:height = "3.0"`）

**⚠️ 注意**：不同资源类型的尺寸属性名不同：
- `BoxMesh` / `BoxShape3D`：使用 `size`
- `CapsuleMesh` / `SphereMesh`：使用 `radius` 和 `height`
- 使用 `get_node_properties` 查看实际可用属性

### 拓展知识
如过程中遇到问题，请查阅 `res://addons/godot_ai_chat/skills/scene_tool_sop/reference/` 文件夹中的相关文档。

### 示例

#### 示例 1：添加节点流程
1. 用户："给 Player 场景加一个 Sprite"
2. AI 调用 `manage_scene_file(action="open", scene_path="res://player.tscn")`
3. (等待工具返回) -> 工具返回场景已打开
4. AI 调用 `get_edited_scene`
5. (等待工具返回) -> 工具返回树结构，确认根节点为 `Player`
6. AI 调用 `manage_scene_structure(action="add_node", parent_path=".", node_class="Sprite2D", node_name="Sprite")`

#### 示例 2：修改基础属性流程
1. 用户："把 Sprite 变红"
2. AI 调用 `get_node_properties(node_path="Sprite")`
3. (等待工具返回) -> 工具返回属性列表，确认 modulate 属性
4. AI 调用 `set_node_properties(node_path="Sprite", property_name="modulate", value="[1, 0, 0, 1]")`

#### 示例 3：设置子资源属性（关键示例）
**任务**：设置 TestCapsule 的胶囊体网格高度为 3.0

**步骤**：
1. AI 调用 `get_node_properties(node_path="TestCapsule")`
   - 查看 mesh 属性的 properties，发现 `height` 和 `radius` 属性
2. AI 调用 `set_node_properties(node_path="TestCapsule", property_name="mesh:height", value="3.0")`
   - **注意**：使用冒号 `:` 而非斜杠 `/`

#### 示例 4：创建资源并设置嵌套属性
**任务**：创建带材质的胶囊体并设置颜色

**步骤**：
1. AI 调用 `set_node_properties(node_path="TestCapsule", property_name="mesh", value="new:CapsuleMesh")`
2. AI 调用 `set_node_properties(node_path="TestCapsule", property_name="mesh:material", value="new:StandardMaterial3D")`
3. AI 调用 `set_node_properties(node_path="TestCapsule", property_name="mesh:material:albedo_color", value="[1, 0, 0]")`
   - **注意**：多级嵌套使用多个冒号 `:`

#### 故障排除

##### 错误：Node not found 'NodeName/mesh/property'
**原因**：使用了斜杠 `/` 访问资源属性
**解决**：改用冒号 `:`，如 `NodeName:mesh:property`

##### 错误：Trying to return value of type "Resource" from a function whose return type is "Node"
**原因**：尝试添加 `Resource` 类型作为场景节点（Resource 不是 Node）
**解决**：Resource 只能作为属性值，不能作为场景节点。使用 `new:ResourceType` 格式设置到节点的资源属性中。

##### 子资源属性设置无效
**原因**：子资源为 null 或未设置为 resource_local_to_scene
**解决**：先确保子资源已创建（如 `mesh = "new:BoxMesh"`），再尝试设置其子属性。
