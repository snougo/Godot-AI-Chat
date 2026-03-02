# Godot AI Chat
[中文](https://github.com/snougo/Godot-AI-Chat/blob/main/README_zh-CN.md)

<img width="1624" height="1080" alt="截屏2026-03-02 22 49 06" src="https://github.com/user-attachments/assets/9fbb86cd-d7a9-427f-b76c-65eab58e8a06" />

## Introduction
**Godot AI Chat** is an AI chat plugin deeply integrated into the Godot editor. Besides standard AI chat features, it also provides **Agent capabilities** implemented based on the `ReAct` framework.


## Core Features

- **Agent Experience**: The `ReAct` agent can autonomously initiate multi-turn dialogue execution through tool calls, which is crucial for building automated workflows.
- **Smart Drag & Drop**: The prompt input box accepts user prompts and supports dragging **files/folders** into it, automatically parsing them into project paths `res://xxxxx`.
- **Smart Conversion**: When the user's prompt contains image paths or scene file paths, the plugin automatically converts them internally into actual images and markdown-formatted scene tree structures.
- **Multimodal Support**: Supports sending images to models with vision capabilities (model support required).
- **Context Sliding Window**: When the number of session turns exceeds the set maximum, the plugin trims the session context based on the set limit before sending, ensuring the context content does not exceed the model's context window.
- **Skill System**: Based on Anthropic's `Skill` concept, this plugin implements its own on-demand loading skill system. It strictly limits mounting to only 1 skill pack at a time, maximizing the maintenance of the model's context window usage.
- **Security Mechanism**: The tool base class `ai_tool.gd` provides path blacklist constants and path blacklist checking methods. This not only prevents AI from accidentally modifying critical files but also makes it convenient for developers to customize project paths they want to lock.
- **Compliant Write Operations**: All tools with write functionality operate on files through engine APIs, ensuring the compliance of file operations.
- **Transparent Invocation**: The chat window supports real-time display of AI tool call details and explicitly shows the call parameters for each tool, making it convenient for developers to detect erroneous AI tool behavior in time to stop it.
- **Real-time Feedback**: All operations on scenes and script files are reflected in real-time on the editor's relevant interfaces, facilitating real-time supervision by developers.
- **Extensibility**: The plugin's architecture achieves maximum module decoupling, making the integration of new API providers and the development of new AI tools very friendly. Errors won't break the plugin's core functionality, which is crucial for real-time debugging of new modules.

> *A ReAct agent is an AI agent that uses the “reasoning and acting” (ReAct) framework to combine chain of thought (CoT) reasoning with external tool use. The ReAct framework enhances the ability of a large language model (LLM) to handle complex tasks and decision-making in agentic workflows.*


## Installation & Enablement

> ⚠️ *Note: This plugin only supports **Godot 4.5** and above.*

1. **Download Dependencies**:
   - Download this plugin: `Godot AI Chat`
   - Download the dependency plugin: [Context Toolkit](https://github.com/snougo/Context-Toolkit)
     > *Context Toolkit is used to provide file context APIs; this plugin's default tool `get_context` depends on it.*

2. **Installation**:
   - Unzip both plugin packages.
   - Drag the `godot_ai_chat` and `context_toolkit` folders into the project's `addons/` directory.

3. **Enablement**:
   - Open the Godot editor, go to `Project` -> `Project Settings` -> `Plugins`.
   - Check to enable `Godot AI Chat` and `Context Toolkit (Optional)`.


## Configuration Guide

When enabled for the first time, a red error message `Please Configure Plugin Settings` will appear in the status bar of the chat interface. This indicates that relevant configurations need to be completed in the **Settings** panel of the plugin interface.

### 1. API Provider Settings
This plugin supports various API standards:

| API Type | Description | Representative Providers |
| :--- | :--- | :--- |
| **OpenAI Compatible** | The most universal standard interface | OpenAI Official, DeepSeek, Kimi (Moonshot), SiliconFlow, OpenRouter, LM Studio (Local), Ollama (Local) |
| **Gemini** | Google native interface | Google Gemini Official |
| **Anthropic Compatible** | Claude series interface | Anthropic Official, some proxy providers |

> ⚠️ *Note: ZhipuAI in the API providers is actually a non-standard OpenAI compatible API, not a special API type.*

> ⚠️ *Note: Coding Plan subscription services provided by model vendors are usually only for their specified clients and most likely cannot be used with this plugin. Please be aware.*

### 2. Base URL (API Address)
The interface address pointing to the AI service provider.

<details>
<summary>Click to view common Base URL list</summary>

- **Local Run (No Key required)**
  - LM Studio: `http://127.0.0.1:1234`
  - Ollama: `http://127.0.0.1:11434/v1`
- **Remote Services**
  - OpenRouter: `https://openrouter.ai/api`
  - Google Gemini: `https://generativelanguage.googleapis.com`
  - Moonshot (Kimi): `https://api.moonshot.cn`
  - SiliconFlow: `https://api.siliconflow.cn`
  - DeepSeek: `https://api.deepseek.com`
  - ZhipuAI: `https://open.bigmodel.cn/api/paas/v4/`

> *Note: If your provider is not in the list, please look for "API Endpoint" or "Base URL" in their documentation.*
</details>

### 3. API Key
- **Remote API Service**: Required.
- **Local API Service** (e.g., LM Studio): Usually can be left empty.

### 4. Other Key Settings
- **Tavily API Key**: The model can only use the `search_web` web search tool normally after configuring this.
- **Max Chat Turns**: Default `12`. Controls the number of dialogue turns sent to the model. Too high may consume a large number of Tokens or trigger limits; too low may lead to context loss.
- **Temperature**: Default `0.8`. Lower values result in more rigorous answers (suitable for coding), while higher values result in more divergent answers (suitable for creativity).
- **Log Level**: Default only checks `Warn` and `Error`. Generally no need to change unless you want to view the plugin's debug status in the editor's Output in real-time.
- **System Prompt**: The system prompt is the first special message sent to the AI model. Unlike normal conversation messages, the model gives higher weight and attention to the system prompt, ensuring all subsequent replies follow its settings.

> *Tips: **Max Chat Turns** can be adjusted dynamically as needed during the session.*

> *Tips: The plugin repository includes a default system prompt document `system_prompt.md` that has undergone multiple iterations. It works out of the box and is recommended for users new to this plugin. You can then make personalized adjustments based on actual needs.*


## Chat Interface Overview

<img width="505" height="836" alt="截屏2026-03-01 23 35 31" src="https://github.com/user-attachments/assets/c97b0f37-98cc-4cef-bfe5-05d2d351b1c9" />

The interface contains from top to bottom:
1. **Status Bar**: Displays plugin working status, error messages, etc., in real-time.
2. **Session Turns**: Real-time monitoring of current session turns and the maximum set session turns.
3. **Token Monitor**: Displays current dialogue and cumulative historical Token consumption, helping you control costs.
4. **Function Area**:
    - **Model Hot-Switch**: Quickly switch between different models.
    - **Session Management**: Create, load, and delete sessions.
5. **Prompt Input Box**: Supports text input and **file drag-and-drop referencing**.
6. **Export and Send**: Save dialogue records as Markdown and the send button.


## Advanced Development

### When is a Skill needed?
`Skill` is a context engineering concept proposed by Anthropic. This plugin provides its own interpretation and implementation of this concept. It is recommended to consider creating a `Skill` when the following scenarios are met:
- Workflows that can be standardized into SOPs.
- Repetitive manual labor that can be proceduralized.
- Some tools have narrow use cases and should not be enabled by default to occupy the model context window; instead, they should be loaded/unloaded on demand.

> *Tips: This plugin has already provided several practical Skills by default. You can refer to the implementation and specifications of these Skills to customize new ones.*

### New AI Tool Development
1. **Minimalist Architecture**: Usually, you only need to inherit the `AiTool` base class and implement 2 interface methods.
2. **Hot Reload**: Add the newly added tool script path to `ToolRegistry.CORE_TOOLS_PATHS` as needed. It takes effect immediately after restarting the plugin. It is recommended to let the AI call the new tool for real-time debugging.

> *Tips: This plugin has already provided multiple AI tools by default. If you need to develop new AI tools, you can refer to the implementation of these tools.*

> *Tips: If you don't want to manually write the implementation of new tools or integrate new API providers, you can let the AI handle it using this plugin's agent function.*

## 📄 License
MIT License.
