# Godot AI Chat

## 简介
**Godot AI Chat** 是一款深度集成于 Godot 编辑器的 AI 助手插件。它不仅仅是一个聊天窗口，更是一个拥有**Agent（智能体）能力**的开发副驾驶。

通过内置的工具链和精心设计的系统提示词，它能够理解你的项目上下文，执行文件操作，甚至通过 API 调用辅助你完成复杂的开发任务。无需离开编辑器，即可构建灵活且强大的 AI 工作流。

## 核心特性

- **Agent 体验**：不仅仅是问答，AI 可以通过工具调用（Function Calling）与编辑器交互，并自主完成交代的任务。
- **智能拖拽**：支持**拖拽**文件/文件夹到输入框，自动解析为项目路径.
- **自动路径处理**：支持发送时将输入框中的图片路径和场景文件路径转换成实际的图片以及markdown格式的场景树结构
- **多模态支持**：支持发送图片给具备视觉能力的模型（需模型支持）。
- **安全机制**：内置路径黑名单和透明的工具参数展示，防止 AI 误操作关键文件。
- **Skill 技能包**：基于 Anthropic 的概念，按需加载/卸载特定能力的工具包，保持上下文整洁。
- **开放的扩展性**：轻松接入 OpenAI、Gemini、Claude、DeepSeek 等主流模型，支持自定义工具开发。


## 安装与启用

> ⚠️ **注意**：本插件仅支持 **Godot 4.5** 及以上版本。

1. **下载依赖**：
   - 下载本插件：`Godot AI Chat`
   - 下载依赖插件：[Context Toolkit](https://github.com/snougo/Context-Toolkit)
     > *Context Toolkit 用于提供文件上下文API，本插件的默认工具`get_context`依赖于它。*

2. **安装**：
   - 解压两个插件包。
   - 将 `godot_ai_chat` 和 `context_toolkit` 文件夹拖入你项目的 `addons/` 目录下。

3. **启用**：
   - 打开 Godot 编辑器，进入 `Project` -> `Project Settings` -> `Plugins`。
   - 勾选启用 `Godot AI Chat` 以及 `Context Toolkit(可选)`。


## 配置指南

初次启用时，状态栏会提示 `Please Configure Plugin Settings`。请在插件界面的 **Settings** 面板完成以下配置。

> ⚠️ **注意**：模型厂商提供的Coding Plan订阅服务通常只能用于它们指定的客户端，所以很可能无法用于本插件。

### 1. API 服务商设置
AI 的核心动力。本插件支持多种 API 标准：

> ⚠️ 注意：API提供商中的ZhipuAI其实是一种非标准的openAI兼容API，而非特殊的API。

| API 类型 | 说明 | 代表厂商 |
| :--- | :--- | :--- |
| **OpenAI 兼容** | 最通用的标准接口 | OpenAI, DeepSeek, Kimi(月之暗面), SiliconFlow(硅基流动), OpenRouter, LM Studio(本地), Ollama(本地) |
| **Gemini** | Google 原生接口 | Google Gemini |
| **Anthropic** | Claude 系列接口 | Anthropic, 部分中转商 |

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

> **提示**：如果你的服务商不在列表中，请查找其文档中的 "API Endpoint" 或 "Base URL"。
</details>

### 3. API Key
- **远程服务**：必填。
- **本地服务**（如 LM Studio）：通常留空即可。

### 4. 其他关键设置
- **Tavily API Key**：配置后模型才可以正常使用 `search_web` 联网搜索工具。
- **Max Chat Turns**：默认 `12`。控制发送给模型的对话轮数，过高可能消耗大量 Token 或触发限制，过低则可能导致上下文丢失。
- **Temperature**：默认 `0.8`。数值越低回答越严谨（适合写代码），数值越高回答越发散（适合创意）。
- **System Prompt**：系统提示词是发送给 AI 模型的第一条特殊消息，与普通对话消息不同，模型会对系统提示词给予更高的权重和关注，确保后续所有回复都遵循其设定。

> 插件仓库包含一份经过精心设计的默认系统提示词文档 `system_prompt.md`，开箱即用，推荐初次使用者先体验默认提示词，然后根据实际需求再进行个性化调整。
> 该提示词针对 Godot 开发场景进行了优化，包含了：
> - 角色设定（Godot 开发助手）
> - 输出风格（中文、简洁）
> - 核心工作流（分析、思考、规划、执行、跟踪）
> - 工作区概念和指令说明


## 界面概览

![Chat Interface](path/to/screenshot.png) *(此处需替换为实际截图)*

界面自上而下包含：
1.  **状态栏**：实时显示插件工作状态、错误提示等。
2.  **Token 监控**：显示当前对话及历史累计的 Token 消耗，助你控制成本。
3.  **功能区**：
    - **模型热切换**：快速在不同模型间切换。
    - **会话管理**：新建、加载、删除、归档对话。
    - **导出**：将对话记录保存为 Markdown。
4.  **智能输入框**：支持文本输入及**文件拖拽引用**。


## 进阶功能

### Skill 系统 (技能包)
基于 Anthropic 的最佳实践，我们将特定的能力封装为 **Skill**。
- **按需加载**：例如"Shader 编写"或"UI 布局"技能，只有在需要时才挂载。
- **节省上下文**：避免将所有工具说明一次性塞给 AI，节省 Token 并提高准确率。
- **SOP 标准化**：将标准作业程序（Standard Operating Procedure）转化为可复用的 AI 技能。

### 新增工具
1.  **自动生成工具**：你可以直接要求 AI："帮我写一个生成噪点纹理的工具脚本，记得实现前先看一眼`ai_tool.gd`"。
2.  **热重载**：将新添加的工具脚本路径加入 `ToolRegistry.CORE_TOOLS_PATHS`，重启插件即可立即生效。
3.  **极简架构**：通常只需继承 `AiTool` 基类并实现 2 个接口方法即可。

## 📄 License
MIT License.