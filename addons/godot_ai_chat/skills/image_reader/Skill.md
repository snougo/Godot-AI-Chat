## Image Reader

### 概览
本技能赋予 Sub-Agent 读取图片文件内容的能力。通过调用 `view_image_tool` 获取图片数据，Sub-Agent 能够分析图片的视觉内容（如场景布局、物体识别、文字识别等），并将结果以文字形式返回给纯文本的 Main-Agent。

### 触发条件
当 Main-Agent 需要理解项目中的图片文件内容时，可创建 Sub-Agent 并指定此技能。

### 指令
1. **接收任务**：接收 Main-Agent 传来的图片路径和具体需求。
2. **读取图片**：调用 `view_image_tool`（参数 `path` 为图片文件路径），获取图片数据。
3. **分析内容**：基于返回的图片数据，分析其视觉内容：
   - 图片类型、尺寸、格式等元数据
   - 图片中的物体、场景、人物等视觉元素
   - 图片中的文字内容（如有）
   - 图片的整体布局和色彩构成
4. **报告结果**：使用 `report_task_result` 工具，将分析结果以文字形式返回给 Main-Agent。

### 示例
- Main-Agent："请帮我查看 `res://assets/screenshot.png` 中的界面布局"
- Sub-Agent 调用 `view_image_tool(path="res://assets/screenshot.png")`
- Sub-Agent 分析图片内容并返回文字描述