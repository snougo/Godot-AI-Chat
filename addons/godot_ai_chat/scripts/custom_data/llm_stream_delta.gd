@tool
class_name LLMStreamDelta
extends RefCounted

## 协议无关的流式增量描述
##
## 由 BaseLLMProvider.parse_stream_chunk() 产出，由 StreamMessageAssembler 消费。
##
## 职责边界（这是本次解耦的核心约定）：
## 1. Provider 只描述「这一块数据里发生了什么」，**不写入任何 ChatMessage**；
## 2. Provider 不产生任何 UI 语义（颜色、状态文案、界面提示）；
## 3. 「如何落地到数据」由 StreamMessageAssembler 单独负责。
##
## [注] 约束的是「不写入」，而非「不感知类型」：Provider 仍会引用
## ChatMessage 的常量（ROLE_* 作角色判断、META_* 作 metadata 键），
## 并以 Array[ChatMessage] 作为请求构建的入参。


# --- Tool Call Delta 字段名 ---

## 槽位稳定键。同一轮流式响应内，同一个工具调用必须始终使用同一个 key
const FIELD_KEY: String = "key"
## 工具调用 ID。空串表示本次不作更新
const FIELD_ID: String = "id"
## 工具名称增量。空串表示本次不作更新；非空则**追加**到槽位名称
const FIELD_NAME: String = "name"
## 工具参数增量。空串表示本次不作更新；非空则**追加**到槽位参数
const FIELD_ARGUMENTS: String = "arguments"
## 工具参数整体覆盖值。非空则**直接覆盖**槽位已累积的参数
const FIELD_ARGUMENTS_SNAPSHOT: String = "arguments_snapshot"


# --- Public Vars ---

## 正文文本增量
var content_delta: String = ""

## 思考内容增量
var reasoning_delta: String = ""

## 需要写入 ChatMessage.metadata 的键值对
## 键名使用 ChatMessage.META_* 常量，避免厂商概念渗入数据模型
var metadata_updates: Dictionary = {}

## 工具调用槽位增量，元素字段见上方 FIELD_* 常量
var tool_call_deltas: Array[Dictionary] = []

## 已归一化的用量信息
## { "prompt_tokens": int, "completion_tokens": int, "total_tokens": int }
var usage: Dictionary = {}

## 该协议是否发出了「流结束」语义
var is_stream_finished: bool = false


# --- Public Functions ---

## 构造一个「工具调用槽位开始」增量
## [param p_key]: 槽位稳定键
## [param p_id]: 工具调用 ID（部分协议此时尚不可知，可传空串）
## [param p_name]: 工具名称（部分协议此时尚不可知，可传空串）
static func make_tool_call_start(p_key: String, p_id: String = "", p_name: String = "") -> Dictionary:
	return {
		FIELD_KEY: p_key,
		FIELD_ID: p_id,
		FIELD_NAME: p_name,
		FIELD_ARGUMENTS: "",
		FIELD_ARGUMENTS_SNAPSHOT: "",
	}


## 构造一个「工具参数追加」增量
## [param p_key]: 槽位稳定键
## [param p_fragment]: 参数片段
static func make_tool_call_arguments_append(p_key: String, p_fragment: String) -> Dictionary:
	return {
		FIELD_KEY: p_key,
		FIELD_ID: "",
		FIELD_NAME: "",
		FIELD_ARGUMENTS: p_fragment,
		FIELD_ARGUMENTS_SNAPSHOT: "",
	}


## 构造一个「工具参数整体覆盖」增量（用于协议在结尾下发权威完整参数的场景）
## [param p_key]: 槽位稳定键
## [param p_full_arguments]: 完整参数字符串
static func make_tool_call_arguments_replace(p_key: String, p_full_arguments: String) -> Dictionary:
	return {
		FIELD_KEY: p_key,
		FIELD_ID: "",
		FIELD_NAME: "",
		FIELD_ARGUMENTS: "",
		FIELD_ARGUMENTS_SNAPSHOT: p_full_arguments,
	}
