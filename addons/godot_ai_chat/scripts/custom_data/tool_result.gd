@tool
class_name ToolResult
extends RefCounted

## 统一工具执行结果类型
##
## 所有工具的 execute() 应返回此类型，编排器通过统一接口读取结果。

# --- Public Vars ---

## 执行是否成功
var success: bool = false

## 发送给 LLM 的文本数据
var data: String = ""

## 可选附件（如图片）{"image_data": PackedByteArray, "mime": String}
var attachments: Dictionary = {}

# --- Public Functions ---

## 创建成功结果
## [param p_data]: 结果文本
static func ok(p_data: String) -> ToolResult:
	var result := ToolResult.new()
	result.success = true
	result.data = p_data
	return result


## 创建成功结果（带图片附件）
## [param p_data]: 结果文本
## [param p_image_data]: 图片字节数据
## [param p_mime]: MIME 类型
static func ok_with_image(p_data: String, p_image_data: PackedByteArray, p_mime: String) -> ToolResult:
	var result := ToolResult.new()
	result.success = true
	result.data = p_data
	result.attachments = {"image_data": p_image_data, "mime": p_mime}
	return result


## 创建失败结果
## [param p_message]: 错误信息
static func fail(p_message: String) -> ToolResult:
	var result := ToolResult.new()
	result.success = false
	result.data = p_message
	return result


## 从旧的 Dictionary 格式适配转换
## 用于兼容尚未迁移到 ToolResult 的技能工具
## [param p_dict]: 旧格式字典 {"success": bool, "data": ..., "attachments"?: ...}
static func from_dict(p_dict: Dictionary) -> ToolResult:
	var result := ToolResult.new()
	result.success = p_dict.get("success", false)
	
	var data_val: Variant = p_dict.get("data", "")
	if data_val is Dictionary or data_val is Array:
		result.data = JSON.stringify(data_val, "\t")
	else:
		result.data = str(data_val)
	
	if p_dict.has("attachments"):
		result.attachments = p_dict.attachments
	return result
