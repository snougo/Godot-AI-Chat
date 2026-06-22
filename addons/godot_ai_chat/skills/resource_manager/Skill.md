# Resource Manager

## 概览
批量创建和编辑 `.tres/.res` 文件。

## 工作流

根据任务描述判断操作类型，进入对应分支，也可以根据任务需求顺序执行所有分支分支：

### 创建资源
适用于：需要新建一个或多个资源文件。

1. **分析需求**：确定要创建的资源类型和数量。

2. **检查路径**：调用 `manage_folder` 确认目标路径是否存在。如果不存在，调用 `manage_folder` 创建。

3. **批量创建**：一次性调用多个 `create_resource` 进行创建。

### 编辑资源
适用于：批量修改已有资源的属性。

1. **列出资源**：调用 `manage_folder` 查看目标文件夹中的已有资源文件。

2. **查询属性**：调用 `get_resource_properties` 查看某个资源的属性名、类型和当前值。

3. **批量编辑**：确认需要编辑的数量和目标后，一次性调用多个调用 `edit_resource` 进行编辑。

### 任务报告
无论最终任务成功与否，调用 `report_task_result` 进行报告。

## 帮助文档
`edit_resource` 工具的详细使用说明，请查阅：`res://addons/godot_ai_chat/skills/resource_manager/reference/edit_resource_guide.md`

## 注意事项
- `edit_resource` 支持 `Color(1,0,0,1)`、`Vector3(1,2,3)`、`true/false` 等字符串格式自动转换
- 资源引用属性（如贴图）传入 `res://` 路径即可自动加载绑定
- `edit_resource` 不会覆盖已存在的文件，而是修改后保存
