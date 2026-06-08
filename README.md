# Godot AI Chat

<img width="1920" height="1080" alt="godot_ai_chat" src="https://github.com/user-attachments/assets/57df923b-1099-4862-938a-5b072038ae22" />

[中文](https://github.com/snougo/Godot-AI-Chat/blob/main/README_zh-CN.md)

## What is this plugin?

Simply put, this is a full-featured AI Agent plugin embedded directly into the Godot editor. It automatically perceives project context, requires no third-party Agent, and needs no MCP.

> After completing the basic feature development in its early stages, this plugin has been continuously iterated upon using itself. This means its engineering implementation comes from real-world experience, not from simple wrapper imitation.

## Installation

1. Download this plugin.
2. Download the dependency plugins: [Context Toolkit](https://github.com/snougo/Context-Toolkit) and [Godot Dom Parser](https://github.com/codeWonderland/godot-dom-parser).
3. Place all plugins into the `addons` folder.
4. Enable this plugin.

> **Note:** Although this plugin's own operation does not depend on any external tools, a few tools invoked by the AI rely on the APIs exposed by the two Godot plugins mentioned above. You only need to download these two plugins and place them in the `addons` folder; there is no need to enable them.

## Plugin Settings

When first enabled, you need to locate the plugin's settings page and fill in the three configuration options: `Base Url`, `API Key`, and `System Prompt`. If you don't know what these settings mean, you can simply send a screenshot to a third-party AI and ask; I won't explain them here.

### Optional Settings

- **Tavily API Key**: Required for the model to properly use the `search_web` internet search tool.
- **Max Chat Turns**: Default is `20`. Controls the number of conversation turns sent to the model. Too high may consume a large number of tokens; too low may cause the model to lose context from earlier in the conversation. It is recommended to adjust this on demand during conversations.
- **Temperature**: Default is `1.0`. Lower values yield more rigorous responses (suitable for coding), while higher values yield more divergent/creative responses (suitable for brainstorming).
- **Log Level**: By default, `Info`, `Warn`, and `Error` are checked. You generally don't need to change this unless you want to view the plugin's Debug output in real-time in the editor's Output panel.

> If you need the web search feature, you can apply for a free API Key at the Tavily official website.

> The plugin repository contains a default system prompt document, `system_prompt.md`, refined over multiple iterations and ready to use out of the box. It is recommended for first-time users to start with this system prompt, then personalize it based on actual needs.

> **Note:** The `Coding Plan` services provided by model vendors can usually only be used in their designated clients and cannot be used in this plugin. Therefore, it is recommended to use the official DeepSeek API service directly. Currently, this service is very inexpensive when the cache is hit. Alternatively, you can use a locally deployed model service such as LM Studio or Ollama.

## How to Use

<img width="349" height="100" alt="截屏2026-06-08 17 59 36" src="https://github.com/user-attachments/assets/14215aa4-cfff-4b41-8d81-d02b3aebf5a5" />

Assuming you have configured it successfully, you should see the plugin status bar display a blue-background, white-text `Ready` status, and see multiple models available in the model selection dropdown. At this point, you can send a `Hello` as a test. If you have topped up your API account, the model should reply immediately.

As for what comes next, you can directly ask the model how to use this plugin, because the plugin's default workspace is the plugin itself.

However, there are some usage tips that are better told to you directly:
- Try to keep each session focused on the same topic or problem. For new topics or questions, start a new session and set the workspace correctly.
- Godot game projects usually contain many files, so good project file management and correct workspace settings can lead to more accurate model outputs.
- This plugin does not enable all AI tools by default. Therefore, you can add the ones you need to the `CORE_TOOLS_PATHS` constant in the `tool_registry.gd` script. However, the recommended approach is to reuse workflows as Skills; you can ask the AI through this plugin directly about how to create custom Skills.
- This plugin supports sending image content to multimodal models. You can experience this feature by deploying a small-parameter multimodal model locally.
- The user input box supports dragging and dropping files into it. After dropping, the file will be automatically processed into a file path. When you click the send button, the plugin will automatically convert the file path into the corresponding content based on the file type.

In short, if you have any questions about this plugin, you can ask the AI directly through this plugin. I won't explain further.

## Beginner Practice Exercises

The following exercises are all based on the plugin's default workspace (i.e., the plugin itself). Because the plugin directory is restricted to read-only, you can feel free to try any operation — it can only read and explain, and will not break any files.

**Step 1: Confirm Connection**
Send `Hello`. If you see a reply from the model, your API configuration is correct.

**Step 2: Let it "understand" this plugin**
Send `What modules does this plugin have?`, then observe how the model responds.

**Step 3: Have it find APIs you are unfamiliar with**
Send `How does this plugin handle streaming requests?`, then observe how the model responds.

**Step 4: Experience "global tracing"**
Send:
```
Search for all references to ChatMessage.ROLE_TOOL across the entire plugin,
then tell me the complete lifecycle of this message — from creation, rendering, to being sent to the API
```
Then observe how the model responds.

**Step 5: Experience multimodality**
Drag any image into the user input box, add the sentence `Describe the content of this image`, click send, and observe the model's response (the model needs to support multimodality, otherwise it will report an error).

## License

MIT License.
