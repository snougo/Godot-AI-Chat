# Godot AI Chat

https://github.com/user-attachments/assets/61972442-9f5c-4365-8c40-0f60c166ed69

## 简介
**Godot AI Chat** 是一款深度集成于Godot编辑器的AI聊天插件。除了普通的AI聊天功能，还提供了基于 `ReAct` 框架实现的**智能体功能**。


## 核心特性

- **Agent体验**：`ReAct` 智能体通过工具调用能自主发起多轮对话的执行，这对于构建自动化工作流至关重要。
- **智能拖拽**：提示词输入框除了接受用户的提示词，还支持拖拽**文件/文件夹** 到输入框中，并自动解析为项目路径 `res://xxxxx` 。
- **智能转换**：当用户发送的提示词中包含有图片路径和场景文件路径时，插件会在内部自动将其转换成实际的图片以及markdown格式的场景树结构。
- **多模态支持**：支持发送图片给具备视觉能力的模型（需模型支持）。
- **上下文滑动窗口**：当会话轮数超过设置的最大值时，插件发送会话上下文时会根据设定的最大值对会话上下文进行裁剪，保证发送的上下文内容不会超过模型的上下文窗口。
- **Skill技能包**：基于Anthropic的 `Skill` 概念，本插件实现了一套自己的按需加载的技能包系统，并且严格限制同一时间只能够挂载1个技能包，最大程度地维护了模型上下文窗口的占用程度。
- **安全机制**：工具基类 `ai_tool.gd` 提供了路径黑名单常量和路径黑名单检查方法，不仅可以防止AI 误操作关键文件，还方便开发者自定义想要锁定的项目路径。
- **合规写入操作**：所有具有写入功能的工具都透过引擎API来对文件进行写入操作，保证了文件操作的合规性，
- **透明调用**：本插件的聊天窗口支持实时显示AI调用工具的详情，并且会显性地显示每个工具的调用参数，方便开发者及时发现AI的错误工具行为，以便及时制止。
- **实时反馈**：所有对于场景和脚本文件的操作都会实时反应在编辑器的相关界面上，方便开发者进行实时监督。
- **二次开发**：本插件在架构实现上进行了最大程度的模块解耦，使得新API服务商的接入和新AI工具的开发都非常友好，不会因为某个错误导致插件的核心功能遭到破坏，这对于进行实时的新模块开发调试至关重要。

> *ReAct代理是一种人工智能代理，它使用“推理和行动”（ReAct）框架将思想链（CoT）推理与外部工具使用相结合。ReAct框架增强了大型语言模型（LLM）处理代理工作流程中复杂任务和决策的能力。*


## 安装与启用

> ⚠️ *注意：本插件仅支持 **Godot 4.5** 及以上版本。*

1. **下载依赖**：
   - 下载本插件：`Godot AI Chat`
   - 下载依赖插件：[Context Toolkit](https://github.com/snougo/Context-Toolkit)
     > *Context Toolkit 用于提供文件上下文API，本插件的默认工具`get_context`依赖于它。*

2. **安装**：
   - 解压两个插件包。
   - 将 `godot_ai_chat` 和 `context_toolkit` 文件夹拖入项目中的 `addons/` 目录下。

3. **启用**：
   - 打开 Godot 编辑器，进入 `Project` -> `Project Settings` -> `Plugins`。
   - 勾选启用 `Godot AI Chat` 以及 `Context Toolkit(可选)`。


## 配置指南

初次启用时，聊天界面的状态栏会出现 `Please Configure Plugin Settings` 的红字错误信息，该信息表示需要在插件界面的 **Settings** 面板完成相关配置。

### 1. API 服务商设置
本插件支持多种 API 标准：

| API 类型 | 说明 | 代表厂商 |
| :--- | :--- | :--- |
| **OpenAI 兼容** | 最通用的标准接口 | OpenAI官方、DeepSeek、Kimi(月之暗面)、SiliconFlow(硅基流动)、OpenRouter、LM Studio(本地)、Ollama(本地) |
| **Gemini** | Google 原生接口 | Google Gemini官方 |
| **Anthropic兼容** | Claude 系列接口 | Anthropic官方、部分中转商 |

> ⚠️ *注意：API提供商中的ZhipuAI其实是一种非标准的openAI兼容API，而非特殊的API。*

> ⚠️ *注意：模型厂商提供的Coding Plan订阅服务通常只能用于它们指定的客户端，很大可能无法用于本插件，特此提醒。*

### 2. Base URL (API 地址)
指向 AI 服务商的接口地址。

<details>
<summary>点击查看常用 Base URL 列表</summary>

- **本地运行 (无需 Key)**
  - LM Studio: `http://127.0.0.1:1234`
  - Ollama: `http://127.0.0.1:11434/v1`
- **远程服务**
  - OpenRouter: `https://openrouter.ai/api`
  - Google Gemini: `https://generativelanguage.googleapis.com`
  - Moonshot (Kimi): `https://api.moonshot.cn`
  - SiliconFlow (硅基流动): `https://api.siliconflow.cn`
  - DeepSeek: `https://api.deepseek.com`
  - ZhipuAI (智谱): `https://open.bigmodel.cn/api/paas/v4/`

> *注意：如果你的服务商不在列表中，请查找其文档中的 "API Endpoint" 或 "Base URL"。*
</details>

### 3. API Key
- **远程API服务**：必填。
- **本地API服务**（如 LM Studio）：通常留空即可。

### 4. 其他关键设置
- **Tavily API Key**：配置后模型才可以正常使用 `search_web` 联网搜索工具。
- **Max Chat Turns**：默认 `12` 。控制发送给模型的对话轮数，过高可能消耗大量 Token 或触发限制，过低则可能导致上下文丢失。
- **Temperature**：默认 `0.8` 。数值越低回答越严谨（适合写代码），数值越高回答越发散（适合创意）。
- **Log Level**：默认只勾选了 `Warn` 和 `Error` ，一般不需要改动，除非你想要在编辑器的Ouput中实时查看插件的debug情况。
- **System Prompt**：系统提示词是发送给 AI 模型的第一条特殊消息，与普通对话消息不同，模型会对系统提示词给予更高的权重和关注，确保后续所有回复都遵循其设定。

> *Tips：**Max Chat Turns**可在会话过程中动态按需调整。*

> *Tips：插件仓库包含一份经过多轮迭代的默认系统提示词文档 `system_prompt.md`，开箱即用，推荐初次上手本插件的用户使用该系统提示词，然后根据实际需求再进行个性化调整。*


## 聊天界面概览

<img width="505" height="836" alt="截屏2026-03-01 23 35 31" src="https://github.com/user-attachments/assets/c97b0f37-98cc-4cef-bfe5-05d2d351b1c9" />

界面自上而下包含：
1. **状态栏**：实时显示插件工作状态、错误提示等。
2. **会话轮数**：实时监控当前会话轮数和设置的最大会话轮数
3. **Token 监控**：显示当前对话及历史累计的 Token 消耗，助你控制成本。
4. **功能区**：
    - **模型热切换**：快速在不同模型间切换。
    - **会话管理**：新建、加载、删除会话。
4. **提示词输入框**：支持文本输入及**文件拖拽引用**。
5. **导出和发送**：将对话记录保存为 Markdown以及发送按钮。


## 进阶二次开发

### 什么时候需要Skill
`Skill` 是由Anthropic提出的一个上下文工程概念，本插件对这个概念进行了自己的诠释和实现。推荐当满足以下几个情景时，可以考虑将其制作成 `Skill` ：
- 可被规范成SOP的工作流。
- 可被流程化的重复体力劳动。
- 一些工具的使用场景狭窄，默认不应该被启用来占用模型上下文窗口，而应按需加载/卸载。

> *Tips：本插件已经默认提供了几套实用的Skill，可以参考这些Skill的是实现和规范来定制新的Skill。*

### 新AI工具开发
1. **极简架构**：通常只需继承 `AiTool` 基类并实现 2 个接口方法即可。
2. **热重载**： 按需将新添加的工具脚本路径加入 `ToolRegistry.CORE_TOOLS_PATHS`，重启插件后立即生效，推荐让AI调用新工具以便进行实时调试。

> *Tips：本插件已经默认提供了多个AI工具，如需开发新的AI工具，可参考这些工具的实现*

> *Tips：如果不想自己手写新工具的实现和新API服务商的接入，完全可以通过本插件的智能体功能来让AI处理。*


## 📄 License
MIT License.
