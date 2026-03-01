# Godot AI Chat
[中文](https://github.com/snougo/Godot-AI-Chat/blob/main/README_zh-CN.md)

https://github.com/user-attachments/assets/43831933-6188-4cc9-895a-63c9e74da4ca

## Introduction
**Godot AI Chat** is an AI assistant plugin deeply integrated into the Godot editor. It is not just a chat window, but a development copilot with **Agent capabilities**.

Through built-in toolchains and carefully designed system prompts, it can understand your project context, perform file operations, and even assist you in completing complex development tasks via API calls. Build flexible and powerful AI workflows without leaving the editor.

## Core Features

- **Agent Experience**: More than just Q&A, the AI can interact with the editor via Function Calling and autonomously complete assigned tasks.
- **Smart Drag-and-Drop**: Supports **dragging** files/folders into the input box, automatically resolving them into project paths.
- **Automatic Path Handling**: Supports converting image paths and scene file paths in the input box into actual images and Markdown-formatted scene tree structures upon sending.
- **Multimodal Support**: Supports sending images to vision-capable models (requires model support).
- **Security Mechanisms**: Built-in path blocklists and transparent tool parameter display to prevent the AI from mishandling critical files.
- **Skill Packages**: Based on Anthropic's concepts, load/unload specific capability toolkits on demand to keep the context clean.
- **Open Extensibility**: Easily connect to mainstream models like OpenAI, Gemini, Claude, and DeepSeek, with support for custom tool development.


## Installation & Setup

> ⚠️ **Note**: This plugin only supports **Godot 4.5** and above.

1. **Download Dependencies**:
   - Download this plugin: `Godot AI Chat`
   - Download dependency plugin: Context Toolkit [<sup>1</sup>](https://github.com/snougo/Context-Toolkit)
     > *Context Toolkit provides file context APIs; this plugin's default tool `get_context` relies on it.*

2. **Install**:
   - Unzip both plugin packages.
   - Drag the `godot_ai_chat` and `context_toolkit` folders into your project's `addons/` directory.

3. **Enable**:
   - Open the Godot Editor, go to `Project` -> `Project Settings` -> `Plugins`.
   - Check the boxes to enable `Godot AI Chat` and `Context Toolkit (Optional)`.


## Configuration Guide

Upon first activation, the status bar will prompt `Please Configure Plugin Settings`. Please complete the following configurations in the plugin's **Settings** panel.

> ⚠️ **Note**: Coding Plan subscription services provided by model vendors can usually only be used with their specific clients, so they likely cannot be used with this plugin.

### 1. API Provider Settings
The core power of the AI. This plugin supports multiple API standards:

> ⚠️ Note: ZhipuAI in the API providers list is actually a non-standard OpenAI-compatible API, rather than a unique API type.

| API Type | Description | Representative Vendors |
| :--- | :--- | :--- |
| **OpenAI Compatible** | The most universal standard interface | OpenAI, DeepSeek, Kimi (Moonshot), SiliconFlow, OpenRouter, LM Studio (Local), Ollama (Local) |
| **Gemini** | Google native interface | Google Gemini |
| **Anthropic** | Claude series interface | Anthropic, some relay services |

### 2. Base URL (API Endpoint)
Points to the AI provider's interface address.

<details>
<summary>Click to view common Base URL list</summary>

- **Local Execution (No Key)**
  - LM Studio: `http://127.0.0.1:1234`
  - Ollama: `http://127.0.0.1:11434/v1`
- **Remote Services**
  - OpenRouter: `https://openrouter.ai/api`
  - Google Gemini: `https://generativelanguage.googleapis.com`
  - Moonshot (Kimi): `https://api.moonshot.cn`
  - SiliconFlow: `https://api.siliconflow.cn`
  - DeepSeek: `https://api.deepseek.com`
  - ZhipuAI: `https://open.bigmodel.cn/api/paas/v4/`

> **Tip**: If your provider is not listed, please check their documentation for "API Endpoint" or "Base URL".
</details>

### 3. API Key
- **Remote Services**: Required.
- **Local Services** (e.g., LM Studio): Usually left empty.

### 4. Other Key Settings
- **Tavily API Key**: The model can only use the `search_web` tool if this is configured.
- **Max Chat Turns**: Default `12`. Controls the number of conversation turns sent to the model. Too high may consume excessive Tokens or trigger limits; too low may cause context loss.
- **Temperature**: Default `0.8`. Lower values make answers more rigorous (suitable for coding), while higher values make answers more divergent (suitable for creativity).
- **System Prompt**: The system prompt is the first special message sent to the AI model. Unlike normal chat messages, the model gives higher weight and attention to the system prompt, ensuring all subsequent replies follow its settings.

> The plugin repository includes a carefully designed default system prompt document `system_prompt.md`, ready to use out of the box. It is recommended that first-time users experience the default prompt first, then personalize it according to actual needs.
> This prompt is optimized for Godot development scenarios, including:
> - Role Setting (Godot Development Assistant)
> - Output Style (Chinese/English, Concise)
> - Core Workflow (Analyze, Think, Plan, Execute, Track)
> - Workspace Concepts and Instruction Explanations


## Interface Overview

<img width="505" height="836" alt="截屏2026-03-01 23 35 31" src="https://github.com/user-attachments/assets/373b9a08-0b48-498d-9c2e-98bc6ddb573c" />

From top to bottom, the interface includes:
1.  **Status Bar**: Displays plugin status, error messages, etc., in real-time.
2.  **Token Monitor**: Displays current conversation and historical cumulative Token usage to help you control costs.
3.  **Function Area**:
    - **Model Hot-Switching**: Quickly switch between different models.
    - **Session Management**: New, Load, Delete, and Archive conversations.
    - **Export**: Save conversation records as Markdown.
4.  **Smart Input Box**: Supports text input and **File Drag-and-Drop Reference**.


## Advanced Features

### Skill System (Skill Packages)
Based on Anthropic's best practices, we encapsulate specific capabilities as **Skills**.
- **On-Demand Loading**: For example, "Shader Writing" or "UI Layout" skills are only mounted when needed.
- **Save Context**: Avoids stuffing all tool instructions into the AI at once, saving Tokens and improving accuracy.
- **SOP Standardization**: Transforms Standard Operating Procedures (SOP) into reusable AI skills.

### Adding New Tools
1.  **Auto-Generation Tool**: You can directly ask the AI: "Help me write a tool script to generate noise textures, remember to look at `ai_tool.gd` first before implementing."
2.  **Hot Reload**: Add the new tool script path to `ToolRegistry.CORE_TOOLS_PATHS` and restart the plugin to take effect immediately.
3.  **Minimalist Architecture**: Usually, you only need to inherit the `AiTool` base class and implement 2 interface methods.

## 📄 License
MIT License.
