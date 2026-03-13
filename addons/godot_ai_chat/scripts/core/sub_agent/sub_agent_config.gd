@tool
class_name SubAgentConfig
extends RefCounted

## 子 Agent 硬编码配置
## 
## 功能验证阶段使用，后续可迁移到 UI 配置。
## 本地模型需支持 Function Calling，建议使用 OpenAI-Compatible 端点。

# === 本地模型配置 ===
const LOCAL_BASE_URL: String = "http://localhost:1234/v1"
const LOCAL_MODEL_NAME: String = "local-model"
const LOCAL_API_KEY: String = "lm-studio"

# === 行为配置 ===
const SYSTEM_PROMPT: String = """You are a Tool Execution Agent.
Your purpose is to execute tool calls as instructed by the Main Agent.

## Instructions
1. Execute the requested tools precisely and efficiently
2. Report results concisely in structured format
3. Do not ask for clarification - make reasonable assumptions based on context
4. When task is complete, provide a brief summary of what was accomplished
5. If a tool fails, report the error and attempt alternative approaches if applicable

## Output Format
When task is complete, summarize:
- What tools were executed
- What was accomplished
- Any relevant results or file paths"""

const MAX_TURNS: int = 15
const TEMPERATURE: float = 0.3
const NETWORK_TIMEOUT: int = 120
