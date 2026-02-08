## Animation State SOP

### 概览
本技能旨在标准化操作 `AnimationNodeStateMachine` 的完整流程，确保AI助手在操作动画状态机搭建时遵循统一规范。

### 触发条件
当用户请求操作动画状态机、添加动画状态、连接动画过渡或验证动画图结构时触发。

### 指令
1. **创建状态机资源**：调用 `create_animation_graph_resource_tool` 工具
   - 参数 `file_path` (必填): 字符串，必须以 `res://` 开头，例如 `"res://characters/player_asm.tres"`
   - 确保目标目录已存在，文件不存在时才会创建

2. **添加状态节点**：调用 `add_animation_state_tool` 工具
   - 参数 `file_path` (必填): 状态机资源路径
   - 参数 `state_name` (必填): 字符串，状态名称（如 `"Idle"`）
   - 参数 `animation_name` (必填): 字符串，关联的动画名称（如 `"idle_animation"`）
   - 参数 `position` (可选): 字符串，格式 `"(x, y)"` 如 `"(100, 50)"`，留空则自动布局

3. **建立状态连接**：调用 `connect_animation_states_tool` 工具
   - 参数 `file_path` (必填): 状态机资源路径
   - 参数 `from_state` (必填): 源状态名称
   - 参数 `to_state` (必填): 目标状态名称
   - 参数 `switch_mode` (可选): 枚举值 `"immediate"` / `"sync"` / `"at_end"`，默认 `"immediate"`
   - 参数 `xfade_time` (可选): 浮点数，交叉淡出时间（秒），默认 `0.0`
   - 参数 `auto_advance` (可选): 布尔值，是否自动推进，默认 `false`
   - 参数 `advance_condition` (可选): 字符串，条件名称，留空则无条件

4. **验证结构完整性**：调用 `get_animation_graph_info_tool` 工具
   - 参数 `file_path` (必填): 状态机资源路径
   - 返回文本摘要，包含所有节点和过渡的详细信息

### 拓展引用
如需深入了解动画状态机工具的使用，请查阅 `res://addons/godot_ai_chat/scripts/tools/animation_state_tool/` 文件夹中的脚本实现。

### 示例
用户指令："在 `res://characters/player_asm.tres` 中，添加一个叫 'Idle' 的状态并关联 idle_anims.clip，再连接到 'Run' 状态，使用同步切换和0.3秒交叉淡出，自动推进。"

AI将按上述指令顺序执行：创建资源 → 添加Idle状态 → 添加Run状态 → 建立Idle到Run的过渡连接 → 验证结构。
