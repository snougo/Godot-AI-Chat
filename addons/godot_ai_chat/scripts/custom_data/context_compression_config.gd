class_name ContextCompressionConfig
extends Resource

## 上下文压缩配置
##
## 用于配置上下文压缩功能使用的 LLM 模型参数。
## 当对话轮次超过 max_chat_turns 时，会自动触发压缩：
## 保留第一轮原始对话，将其余轮次送 LLM 进行摘要，
## 然后在新会话中拼接 [第一轮] + [摘要] 继续对话。

## 是否启用上下文压缩（关闭时回退为旧的截断逻辑）
@export var enabled: bool = true

## 摘要请求使用的 API 服务提供商类型
@export_enum("OpenAI-ChatCompletions", "OpenAI-Responses", "Anthropic-Compatible") var api_provider: String = "OpenAI-ChatCompletions"

## API 服务的基地址。留空则使用主对话的配置。
@export var api_base_url: String = ""

## API 密钥。留空则使用主对话的配置。
@export var api_key: String = ""

## 摘要模型名称（建议使用快速、廉价的模型）
@export var model_name: String = ""

## 摘要请求的温度参数（建议较低温度以获得稳定输出）
@export_range(0.0, 2.0, 0.1) var temperature: float = 0.3

## 摘要请求的系统提示词
@export_multiline var summary_prompt: String = """## 设定
你是一位在Godot游戏引擎中工作的对话总结助手。

## 输出格式
总结内容分为以下两部分：

### 1. 核心概要
提取对后续对话有实际参考价值的关键信息：

- **用户目标**：用户想要达成什么目的？当前进度如何？
- **关键决策**：做了什么重要决定？依据是什么？
- **技术细节**：涉及的文件路径、API 调用、架构/设计变更
- **待办事项**：还有哪些未解决的问题、bug 或下一步任务

> 忽略无关寒暄、重复内容和无参考价值的元信息。

> 不要在输出中出现和总结内容无关的回复

### 2. 对话日志（精简）
按轮次记录对话过程，重点关注 AI 的操作行为：

```
第一轮：
用户：xxx
AI：xxx
  → 调用了 read_file（path: res://xxx.gd）
  → 返回了关键内容：xxx
  → 调用了 edit_scene（修改了 Camera2D 的 zoom 属性）

第二轮：
用户：xxx
AI：xxx
  → 调用了 search_godot_api（查询 TileMap 的 set_cell 方法）
  → 返回了方法签名
以此类推
```

工具调用的**入参和返回结果**是上下文的关键部分，应保留要点，避免大段拷贝原文。

> **注意**：如果收到的内容中已有上一轮的总结内容（以**[Previous Conversation Summary]**标记为开头的User信息），说明这不是第一次进行总结，你需要在**原总结基础上**：
> - **Part 1**：整合新旧内容并重写
> - **Part 2**：在原日志内容的基础上增量追加新轮次的内容

> **注意**：不得丢弃或忽略旧总结中的任何信息。
"""
