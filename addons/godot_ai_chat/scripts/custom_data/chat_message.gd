@tool
extends Resource
class_name ChatMessage

# 定义常量，供代码中调用，避免魔法字符串拼写错误
# 使用方法: var msg = ChatMessage.new(ChatMessage.ROLE_USER, "hello")
const ROLE_USER = "user"
const ROLE_ASSISTANT = "assistant"
const ROLE_SYSTEM = "system"
const ROLE_TOOL = "tool"

# 角色定义：使用 export_enum 限制编辑器内的选择，但底层依然是 String，方便 JSON 序列化
@export_enum("user", "assistant", "system", "tool") var role: String = ROLE_USER

# 发送者的名称。
# 1. 对于 role="tool"，这里必须存储工具的名称 (Gemini 必需)。
# 2. 对于 role="user"，可以存储用户名 (OpenAI 支持)。
@export var name: String = "" 

# 消息内容
@export_multiline var content: String = ""

# [新增] 思考内容 (Chain of Thought / Reasoning)
# 用于存储 DeepSeek-R1 / Kimi 等模型输出的思维链内容
@export_multiline var reasoning_content: String = ""

# 图片内容
@export var image_data: PackedByteArray = [] # 存储图片原始字节
@export var image_mime: String = "image/png" # 默认为 PNG

# --- 工具调用相关 (Agent) ---

# [Assistant 专用]
# 存储模型生成的工具调用请求。
@export var tool_calls: Array = []

# [Tool 专用]
# 如果这是一条 role="tool" 的消息，该字段存储对应的 call_id
@export var tool_call_id: String = ""

# [Gemini 专用]
# 用于在多轮工具调用中维持 Gemini 的思维链签名
@export var gemini_thought_signature: String = ""


func _init(p_role: String = ROLE_USER, p_content: String = "", p_name: String = "") -> void:
	role = p_role
	content = p_content
	name = p_name


# [核心修复] 根据角色生成严格符合 OpenAI 规范的字典
func to_api_dict() -> Dictionary:
	var dict: Dictionary = {
		"role": role
	}
	
	# 1. 处理 Content
	# OpenAI 规定：如果 assistant 消息有 tool_calls，content 可以为 null
	# 如果是普通消息，content 必须存在
	if role == ROLE_ASSISTANT and not tool_calls.is_empty() and content.is_empty():
		dict["content"] = null
	else:
		dict["content"] = content
	
	# 2. 处理 Name
	# OpenAI 规定：role=tool 时不需要 name (只看 tool_call_id)
	# role=user 时可以有 name
	# role=function (已废弃) 才必须有 name
	if not name.is_empty() and role != ROLE_TOOL:
		dict["name"] = name
	
	# 3. 处理 Tool Calls
	if not tool_calls.is_empty():
		dict["tool_calls"] = tool_calls
	
	# 4. 处理 Tool Call ID
	if not tool_call_id.is_empty():
		dict["tool_call_id"] = tool_call_id
	
	return dict
