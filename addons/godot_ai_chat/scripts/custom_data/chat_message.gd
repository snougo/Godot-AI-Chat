@tool
class_name ChatMessage
extends Resource

## 聊天消息数据结构
##
## 定义单条聊天消息的数据结构，支持多模态和工具调用。

# --- Constants ---

## 用户角色
const ROLE_USER: String = "user"
## 助手角色
const ROLE_ASSISTANT: String = "assistant"
## 系统角色
const ROLE_SYSTEM: String = "system"
## 工具角色
const ROLE_TOOL: String = "tool"

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

## [新增] 多图支持
## 存储格式: [{"data": PackedByteArray, "mime": String}]
@export var images: Array[Dictionary] = []

# [过时] 仅作兼容保留
## 存储图片原始字节
@export var image_data: PackedByteArray = PackedByteArray()
## 图片 MIME 类型，默认为 image/png
@export var image_mime: String = "image/png"

# --- Tool Call Vars ---

## [Assistant 专用] 存储模型生成的工具调用请求
@export var tool_calls: Array = []

## [Tool 专用] 如果这是一条 role="tool" 的消息，该字段存储对应的 call_id
@export var tool_call_id: String = ""

## [Gemini 专用] 用于在多轮工具调用中维持 Gemini 的思维链签名
@export var gemini_thought_signature: String = ""


# --- Built-in Functions ---

func _init(p_role: String = ROLE_USER, p_content: String = "", p_name: String = "") -> void:
	role = p_role
	content = p_content
	name = p_name


# --- Public Functions ---

## [新增] 便捷添加图片
func add_image(p_data: PackedByteArray, p_mime: String) -> void:
	if not p_data.is_empty():
		images.append({"data": p_data, "mime": p_mime})
		
		# [兼容旧逻辑] 如果是第一张图，同时也填充到旧字段
		if images.size() == 1:
			image_data = p_data
			image_mime = p_mime
