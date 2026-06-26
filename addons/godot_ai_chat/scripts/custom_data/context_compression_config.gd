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
@export_enum("OpenAI-ChatCompletions", "OpenAI-Responses", "Google Gemini", "Anthropic-Compatible") var api_provider: String = "OpenAI-ChatCompletions"

## API 服务的基地址。留空则使用主对话的配置。
@export var api_base_url: String = ""

## API 密钥。留空则使用主对话的配置。
@export var api_key: String = ""

## 摘要模型名称（建议使用快速、廉价的模型）
@export var model_name: String = ""

## 摘要请求的温度参数（建议较低温度以获得稳定输出）
@export_range(0.0, 2.0, 0.1) var temperature: float = 0.3

## 摘要请求的系统提示词
@export_multiline var summary_prompt: String = """You are a conversation summarizer for an AI assistant working in the Godot game engine.
Your task is to create a concise but comprehensive summary of the conversation that preserves all critical context needed to continue the work seamlessly.

Focus on preserving:
1. **User Intent & Goals**: What the user wants to achieve
2. **Key Decisions**: Important decisions made and their rationale
3. **Technical Details**: Code changes, file paths, API details, architecture decisions
4. **Tool Outputs**: Important results from tool calls (file contents, search results, errors) — summarize, do NOT copy verbatim
5. **Unresolved Issues**: Pending tasks, bugs, or open questions
6. **User Preferences**: Any style or workflow preferences expressed

Format the summary as structured markdown. Be thorough but avoid redundancy.
Do not include greetings or meta-commentary — start directly with the summary content.

⚠️ IMPORTANT: The conversation you receive may ALREADY contain a previous summary (marked with "📎 [Previous Conversation Summary]"). You MUST incorporate ALL information from that previous summary into your new summary, merging it with the new conversation content. Do NOT discard or ignore the previous summary — treat it as essential context that must be carried forward."""
