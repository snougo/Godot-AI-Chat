# Godot AI Chat
English/中文

## About Godot AI Chat
Godot AI Chat is a Godot plugin that enables direct conversation with LLMs within the Godot editor interface. It supports both local and remote LLMs. When combined with another Godot plugin, Context Toolkit, and appropriate system prompts, it allows the LLM to actively read relevant contextual information while solving problems, thereby providing more pertinent answers.

## How to Install and Enable
1.  Download the Godot AI Chat and Context Toolkit (optional) plugins.
2.  Drag the downloaded plugin folders into the `addons` folder in your editor's file system.
3.  Open Project Settings, switch to the Plugins tab, find and enable Godot AI Chat and Context Toolkit (optional).

## How to Set Up the Plugin
When you first enable the plugin, you'll see an error message in the plugin interface: "API Base Url is not set in Settings." This indicates that you need to manually fill in the relevant settings. Please click the "Settings" tab in the plugin interface to access the settings options.

When you first enter the plugin's settings options, you'll see an interface where only "Base Url" and "API Key" (optional) need to be manually configured.

Settings options screenshot (placeholder text for image)

If you only need the chat functionality, simply fill in the correct Base Url and API Key (optional). If you have also enabled the Context Toolkit plugin, you will need to modify the default system prompt. Don't worry, I have provided corresponding Chinese and English versions of the system prompt in the plugin folder. Of course, if you are a speaker of another language, you can have AI translate the provided system prompts into your language. For other settings, if you are unsure what they do, you can keep them at their defaults. Finally, click the "Save" button to apply your changes.

### Setting Options Explanation

-   **Base Url**:
    Points to the API base address of the AI service provider you are using. For example:
    -   For **LM Studio** (OpenAI-compatible API): `http://127.0.0.1:1234`
    -   For **OpenRouter** (OpenAI-compatible API): `https://openrouter.ai/api`
    -   For **Local Ollama service** (OpenAI-compatible API): `http://localhost:11434`
    -   For **Google Gemini** (Gemini official API): `https://generativelanguage.googleapis.com`
    > Note: This plugin only supports OpenAI-compatible API addresses designed with standard `/v1/...` endpoints. Other non-standard endpoint designs for OpenAI-compatible API addresses cannot be used normally.

-   **API Key**: Used for authenticating access to the AI service provider. Local services (e.g., LM Studio, Ollama) do not require an API key, but remote APIs (e.g., OpenAI, Google Gemini, etc.) must provide a valid key.

-   **Max Chat Turns**: Controls the number of historical turns retained in each conversation. The default value is 5. Setting it too low may lead to context loss (e.g., the model cannot understand user intent), while setting it too high may exceed the model's context window, triggering API limits, or causing performance degradation.
    > Recommended values: 3 to 10, can be dynamically modified during chat.

-   **Timeout (sec)**: Sets the timeout duration for conversation requests (in seconds). The default value is 180 seconds. If the API response is slow or the network is unstable, you can appropriately extend this.

-   **Temperature**: Controls the "creativity" level of the model's output. Lower values (e.g., 0.1) result in more conservative, deterministic output; higher values (e.g., 1.0) result in more random, creative output.
    > Recommended values: 0.5 to 0.8, balancing stability and diversity.

-   **System Prompt**: Used to guide the role or behavior the model should adopt during the conversation.