# Godot AI Chat

<img width="1624" height="983" alt="截屏2025-10-22 03 16 16" src="https://github.com/user-attachments/assets/a4df1037-3562-4566-b528-dbd83f2f8e4f" />

## 关于Godot AI Chat
Godot AI Chat是一款支持在Godot编辑器界面中直接和LLM聊天的Godot插件，支持和本地LLM或者远程LLM聊天，配合另一款Godot插件[Context Toolkit](https://github.com/snougo/Context-Toolkit)以及相应的系统提示词，还能让LLM在解决问题的过程中主动读取相关上下文信息，以便提供更加相关的回答。

## 如何安装和启用
1. 下载插件Godot AI Chat和[Context Toolki](https://github.com/snougo/Context-Toolkit)
2. 将下载后的插件文件夹拖入到编辑器文件系统中的addon文件夹中
3. 打开Project Settings，切换到Plugins标签，找到并启用Godot AI Chat和Context Toolki（可选）

## 如何设置插件
当你初次启用插件后，你会看到插件界面的错误提示：API Base Url is not set in Settings，这是提示你需要手动填写相关设置内容，请点击插件界面中的Settings标签进入设置选项。

当你第一次进入插件的设置选项时，你会看到这样的界面，其中需要手动设置的项目只有Base Url和API Key（可选）。

设置选项截图

<img width="513" height="838" alt="截屏2025-10-22 03 14 50" src="https://github.com/user-attachments/assets/f33cec84-5221-47e3-9d38-b222638d205e" />


如果你只需要聊天功能，那么只需填写正确的Base Url和API Key（可选）即可，如果你同时启用了[Context Toolkit](https://github.com/snougo/Context-Toolkit)插件，那么你还需要修改默认的系统提示词，不过别担心，我已经在插件文件夹中提供了相应的中英文版本的系统提示词，当然如果你是其他语言的使用者，可以将我提供的系统提示词让AI翻译成对应的语言即可，其余的设置你如果不清楚是做什么的可以保持默认，最后点击保存按钮应用修改结果。

### 设置选项解释

- **Base Url**：
指向你所使用的AI服务提供商的API基础地址。例如：
  - 使用 **LM Studio**（openAI兼容API）：`http://127.0.0.1:1234`
  - 使用 **OpenRouter**（openAI兼容API）：`https://openrouter.ai/api`
  - 使用 **本地Ollama服务**（openAI兼容API）：`http://localhost:11434`
  - 使用 **Google Gemini**（Gemini官方API）：`https://generativelanguage.googleapis.com`
  > 注意：由于本插件只支持标准的`/v1/...`端点设计的openAI兼容API地址，其他非标准端点设计的openAI兼容API地址无法正常使用。

- **API Key**：用于认证访问AI服务提供商的密钥。本地服务（如LM Studio、Ollama）无需填写，但远程API（如OpenAI、Google Gemini等）必须提供有效密钥。

- **Max Chat Turns**：控制每次对话中保留的历史轮次数量。默认值为5，设置过低可能导致上下文丢失（如模型无法理解用户意图），过高则可能超过模型的上下文窗口触发API限制或性能下降。  
  > 推荐值：3~10，可在聊天过程中动态修改。

- **Timeout（sec）**：设置对话请求的超时时间（单位：秒）。默认值为180秒。若API响应缓慢或网络不稳定，可适当延长。

- **Temperature**：控制模型输出的“创造性”程度。值越低（如0.1），输出越保守、确定；值越高（如1.0），输出越随机、创意。  
  > 推荐值：0.5~0.8，平衡稳定性和多样性。

- **System Prompt**：用于指导模型在对话中扮演的角色或行为。

