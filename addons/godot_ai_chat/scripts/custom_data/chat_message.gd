@tool
class_name ChatMessage
extends Resource

## 聊天消息数据结构
##
## 定义单条聊天消息的数据结构，支持多模态与工具调用。
## 厂商/协议专属的流内信息统一收入 metadata 字典，
## 使数据模型不再暴露任何具体协议概念。


# --- Constants ---

## 用户角色
const ROLE_USER: String = "user"
## 助手角色
const ROLE_ASSISTANT: String = "assistant"
## 系统角色
const ROLE_SYSTEM: String = "system"
## 工具角色
const ROLE_TOOL: String = "tool"
## metadata 键：生成该条消息时使用的模型名
const META_MODEL_NAME: String = "model_name"


## metadata 键：Anthropic extended thinking 块签名（多轮 thinking 会话回传必需）
const META_THINKING_SIGNATURE: String = "thinking_signature"
## metadata 键：Gemini thoughtSignature（多轮工具调用中维持思维链必需）
const META_GEMINI_THOUGHT_SIGNATURE: String = "gemini_thought_signature"


# --- @export Vars ---

## 角色定义
@export_enum("user", "assistant", "system", "tool") var role: String = ROLE_USER

## 发送者的名称
## 1. 对于 role="tool"，这里必须存储工具的名称 (Gemini 必需)。
## 2. 对于 role="user"，可以存储用户名 (OpenAI 支持)。
@export var name: String = ""

## 消息正文内容
@export_multiline var content: String = ""

## 思考内容 (Chain of Thought / Reasoning)
## 用于存储 DeepSeek-R1 / Kimi 等模型输出的思维链内容
@export_multiline var reasoning_content: String = ""

## 多图支持
## 存储格式: [{"data": PackedByteArray, "mime": String}]
@export var images: Array[Dictionary] = []

## 协议适配元数据：厂商专属的流内信息
## 已知键见 META_THINKING_SIGNATURE / META_GEMINI_THOUGHT_SIGNATURE
## 由 Provider 通过 LLMStreamDelta.metadata_updates 写入
@export var metadata: Dictionary = {}


# --- Tool Call Vars ---

## [Assistant 专用] 存储模型生成的工具调用请求
@export var tool_calls: Array = []

## [Tool 专用] 如果这是一条 role="tool" 的消息，该字段存储对应的 call_id
@export var tool_call_id: String = ""


# --- Built-in Functions ---

func _init(p_role: String = ROLE_USER, p_content: String = "", p_name: String = "") -> void:
	role = p_role
	content = p_content
	name = p_name


# --- Public Functions ---

## 便捷添加图片
func add_image(p_data: PackedByteArray, p_mime: String) -> void:
	if not p_data.is_empty():
		images.append({"data": p_data, "mime": p_mime})
