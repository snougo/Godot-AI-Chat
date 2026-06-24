# Resource Manager

## 概览
批量创建和编辑 `.tres/.res` 文件。

## 工作流
1. 阅读帮助文档。
2. 检视现有的状况。
3. 根据 Main-Agent 发布的任务和现状制定计划。
4. 将计划拆解成执行步骤，并逐一添加成待办事项。
5. 按照顺序执行待办事项直到完成。
6. 检查工作结果，如果符合任务要求则直接向 Main-Agent 报告任务执行结果，否则继续进行迭代优化。

> 提示：为了节省任务执行所花费的时间和token，一些无关上下文限制的操作可以批量调用工具一次性执行完毕。

## 注意事项
- `edit_resource` 支持 `Color(1,0,0,1)`、`Vector3(1,2,3)`、`true/false` 等字符串格式自动转换
- `edit_resource` 不会覆盖已存在的文件，而是修改后保存
- 资源引用属性（如贴图）传入 `res://` 路径即可自动加载绑定

## 帮助文档
`edit_resource` 工具的详细使用说明，请查阅：`res://addons/godot_ai_chat/skills/resource_manager/reference/edit_resource_guide.md`
